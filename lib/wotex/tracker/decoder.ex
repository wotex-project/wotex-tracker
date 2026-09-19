defmodule Wotex.Tracker.Decoder do
  @moduledoc """
  An explicit trusted decoder seam. A caller supplies `{revision, function}`;
  the wire never selects executable code. Unknown/ambiguous resolution prevents
  callback execution. Caller-supplied callbacks must be pure and deterministic.
  Programming errors in trusted callbacks are not swallowed.

  The callback returns
  `{:ok, %{measurements: [Measurement.t()], positions: [map()], identity: map()}}`
  or a typed error. Position maps are closed `wtr.position.v1` claims; the wrapper
  binds them to observation/profile/decoder lineage before admitting `Position`
  values. It validates the entire return and returns one immutable evidence bundle.
  """

  alias Wotex.Tracker.{
    Admission,
    Capability,
    Error,
    Evidence,
    EvidenceBundle,
    Limits,
    Measurement,
    Position,
    Resolution
  }

  @type t :: %__MODULE__{
          bundle: EvidenceBundle.t(),
          capabilities: [Capability.t()],
          measurements: [Measurement.t()],
          positions: [Position.t()],
          resolution: Resolution.t()
        }
  @enforce_keys [:bundle, :capabilities, :measurements, :positions, :resolution]
  defstruct @enforce_keys

  @doc "Runs only the explicitly supplied matching decoder and admits its complete output."
  @spec run(term(), term(), term(), term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def run(observation, resolution, catalogue, configured, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         {:ok, resolution} <- Resolution.validate(resolution, observation, catalogue, options),
         :ok <- eligible(resolution),
         {:ok, callback} <- callback(configured, resolution.selected.decoder),
         {:ok, output} <- result(callback.(observation), limits, options) do
      admit_output(output, observation, resolution, options)
    end
  end

  @doc "Revalidates decoded evidence against its exact observation and catalogue without rerunning code."
  @spec validate(term(), term(), term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(value, observation, catalogue, options \\ [])

  def validate(
        %__MODULE__{
          resolution: resolution,
          measurements: measurements,
          positions: positions,
          bundle: bundle
        } = value,
        observation,
        catalogue,
        options
      ) do
    with {:ok, limits} <- Limits.new(options),
         {:ok, resolution} <- Resolution.validate(resolution, observation, catalogue, options),
         :ok <- eligible(resolution),
         {:ok, bundle} <- EvidenceBundle.validate(bundle, options),
         {:ok, identity} <- identity_output(bundle),
         {:ok, position_claims} <- stored_position_claims(positions),
         {:ok, output} <-
           result(
             {:ok, %{measurements: measurements, positions: position_claims, identity: identity}},
             limits,
             options
           ),
         {:ok, admitted} <- admit_output(output, observation, resolution, options),
         true <- admitted === value do
      {:ok, admitted}
    else
      false -> {:error, Error.new(:invalid_decoder_result, :decode)}
      error -> error
    end
  end

  def validate(_, _, _, _), do: {:error, Error.new(:invalid_decoder_result, :decode)}

  defp identity_output(bundle) do
    case Enum.filter(Map.values(bundle.evidence), &(&1.kind == :identity)) do
      [identity] -> {:ok, identity.claim}
      _ -> {:error, Error.new(:invalid_decoder_result, :decode)}
    end
  end

  defp stored_position_claims(positions) when is_list(positions) do
    Enum.reduce_while(positions, {:ok, []}, fn
      %Position{claim: claim}, {:ok, claims} -> {:cont, {:ok, [claim | claims]}}
      _, _ -> {:halt, {:error, Error.new(:invalid_decoder_result, :decode)}}
    end)
    |> case do
      {:ok, claims} -> {:ok, Enum.reverse(claims)}
      error -> error
    end
  end

  defp stored_position_claims(_), do: {:error, Error.new(:invalid_decoder_result, :decode)}

  defp build(output, observation, resolution, options) do
    with {:ok, evidence, descriptors, position_ids} <-
           evidence(output, observation, resolution, options),
         {:ok, bundle} <- EvidenceBundle.new([observation], evidence, options),
         {:ok, capabilities} <- capabilities(descriptors, bundle, options),
         {:ok, positions} <- positions(position_ids, bundle, options) do
      {:ok,
       %__MODULE__{
         bundle: bundle,
         capabilities: capabilities,
         measurements: output.measurements,
         positions: positions,
         resolution: resolution
       }}
    end
  end

  defp admit_output(output, observation, resolution, options) do
    case build(output, observation, resolution, options) do
      {:ok, _} = admitted -> admitted
      {:error, _} -> {:error, Error.new(:invalid_decoder_result, :decode)}
    end
  end

  defp eligible(%{status: :resolved}), do: :ok
  defp eligible(_), do: {:error, Error.new(:unknown_resolution, :decode)}

  defp callback({revision, function}, revision) when is_function(function, 1), do: {:ok, function}
  defp callback(_, _), do: {:error, Error.new(:revision_mismatch, :decode)}

  defp result({:ok, output}, limits, options) do
    with :ok <- Admission.fields(output, [:measurements, :positions, :identity]),
         :ok <- Admission.bounded_list(output.measurements, limits.max_claims),
         :ok <- Admission.bounded_list(output.positions, limits.max_sources),
         :ok <- Admission.object(output.identity, limits),
         :ok <- Admission.each(output.measurements, &measurement(&1, options)),
         :ok <- Admission.each(output.positions, &position_claim(&1, limits, options)),
         true <- length(output.positions) == length(Enum.uniq(output.positions)),
         :ok <- Admission.ids(Enum.map(output.measurements, & &1.kind), limits, limits.max_claims) do
      {:ok, output}
    else
      false -> {:error, Error.new(:invalid_decoder_result, :decode)}
      {:error, _} -> {:error, Error.new(:invalid_decoder_result, :decode)}
    end
  end

  defp result({:error, %Error{code: code, phase: phase, path: path} = error}, _limits, _options) do
    normalized = Error.new(code, phase, path)

    if normalized === error,
      do: {:error, error},
      else: {:error, Error.new(:invalid_decoder_result, :decode)}
  end

  defp result(_, _, _), do: {:error, Error.new(:invalid_decoder_result, :decode)}

  defp measurement(value, options) do
    case Measurement.validate(value, options) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp position_claim(value, limits, options) do
    with :ok <- Admission.object(value, limits), do: Position.admit_claim(value, options)
  end

  defp evidence(output, observation, resolution, options) do
    Enum.reduce_while(output.measurements, {:ok, [], [], []}, fn measurement,
                                                                 {:ok, evidence, descriptors,
                                                                  position_ids} ->
      with {:ok, claim} <- Measurement.to_map(measurement, options),
           {:ok, sample} <- claim(:measurement, claim, [], observation, resolution, options),
           support = %{
             "capability" => measurement.kind,
             "unit" => measurement.unit,
             "interaction" => "property",
             "operations" => ["read"]
           },
           {:ok, capability} <-
             claim(:capability, support, [sample.id], observation, resolution, options) do
        descriptor = %{
          id: measurement.kind,
          kind: :property,
          operations: [:read],
          unit: measurement.unit,
          evidence_ids: [capability.id]
        }

        {:cont, {:ok, [capability, sample | evidence], [descriptor | descriptors], position_ids}}
      else
        error -> {:halt, error}
      end
    end)
    |> position_claims(output.positions, observation, resolution, options)
    |> identity_claim(output.identity, observation, resolution, options)
  end

  defp position_claims(
         {:ok, evidence, descriptors, ids},
         claims,
         observation,
         resolution,
         options
       ) do
    Enum.reduce_while(claims, {:ok, evidence, descriptors, ids}, fn position,
                                                                    {:ok, evidence, descriptors,
                                                                     ids} ->
      case claim(:position, position, [], observation, resolution, options) do
        {:ok, admitted} -> {:cont, {:ok, [admitted | evidence], descriptors, [admitted.id | ids]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, evidence, descriptors, ids} ->
        {:ok, evidence, descriptors, Enum.reverse(ids)}

      error ->
        error
    end
  end

  defp position_claims(error, _, _, _, _), do: error

  defp identity_claim(
         {:ok, evidence, descriptors, position_ids},
         identity,
         observation,
         resolution,
         options
       ) do
    with {:ok, claim} <- claim(:identity, identity, [], observation, resolution, options),
         do: {:ok, [claim | evidence], Enum.reverse(descriptors), position_ids}
  end

  defp identity_claim(error, _, _, _, _), do: error

  defp claim(kind, claim, parents, observation, resolution, options) do
    profile = resolution.selected

    preimage = %{
      "schema" => "wtr.decoded-claim.v1",
      "kind" => Atom.to_string(kind),
      "claim" => claim,
      "parents" => parents,
      "observation" => resolution.observation_identity,
      "catalogue" => resolution.catalogue_identity
    }

    with {:ok, limits} <- Limits.new(options),
         {:ok, id} <- Admission.digest(preimage, Limits.json(limits)) do
      Evidence.new(
        %{
          id: id,
          kind: kind,
          claim: claim,
          source_observation_ids: [observation.id],
          evidence_ids: parents,
          profile: {profile.id, profile.version},
          decoder: profile.decoder,
          confidence: profile.confidence,
          reasons: ["declared_decoder_output"],
          association_id: nil
        },
        options
      )
    end
  end

  defp capabilities(descriptors, bundle, options) do
    Enum.reduce_while(descriptors, {:ok, []}, fn descriptor, {:ok, acc} ->
      case Capability.new(descriptor, bundle, options) do
        {:ok, capability} -> {:cont, {:ok, [capability | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp positions(ids, bundle, options) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, positions} ->
      case Position.new(id, bundle, options) do
        {:ok, position} -> {:cont, {:ok, [position | positions]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, positions} -> {:ok, Enum.reverse(positions)}
      error -> error
    end
  end
end
