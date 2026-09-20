defmodule Wotex.Tracker.Protocols.Teltonika.TAT140Import do
  @moduledoc """
  Admits one configured TAT140 frame as ordered, evidence-backed AVL records.

  The ordinary decoder seam intentionally represents one set of measurement
  kinds per observation. This record-aware seam instead keeps every AVL record
  distinct. Each record receives a private transport claim containing its
  trigger, GPS state and complete IO bytes; measurement and position claims
  reference that record claim. Capability evidence is derived once from the
  exact immutable profile mapping, so support does not disappear when a record
  lacks a current sample or GPS fix.

  `run/3` resolves the exact packaged profile and records a closed evidence
  bundle. `validate/4` repeats the pure import and rejects altered structs,
  observations or catalogue snapshots. Neither function performs IO.
  """

  alias Wotex.Tracker.{
    Admission,
    Capability,
    Catalogue,
    Error,
    Evidence,
    EvidenceBundle,
    Limits,
    Measurement,
    Observation,
    Position,
    Resolution
  }

  alias Wotex.Tracker.Protocols.Teltonika.TAT140

  @units %{"batteryVoltage" => "V", "motion" => "1", "position" => "WGS84"}

  @type mapped_record :: %{
          index: non_neg_integer(),
          timestamp_ms: non_neg_integer(),
          priority: :low | :high | :panic,
          trigger: map(),
          transport_evidence_id: String.t(),
          measurement_evidence_ids: [String.t()],
          position_evidence_ids: [String.t()],
          measurements: [Measurement.t()],
          positions: [Position.t()]
        }
  @type t :: %__MODULE__{
          bundle: EvidenceBundle.t(),
          capabilities: [Capability.t()],
          records: [mapped_record()],
          resolution: Resolution.t()
        }
  @enforce_keys [:bundle, :capabilities, :records, :resolution]
  defstruct @enforce_keys

  @doc "Builds ordered record evidence for the exact configured TAT140 profile."
  @spec run(term(), term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def run(observation, catalogue, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         {:ok, observation} <- Observation.validate(observation, options),
         {:ok, catalogue} <- Catalogue.validate(catalogue, options),
         {:ok, resolution} <- Resolution.resolve(observation, catalogue, options),
         {:ok, profile} <- exact_profile(resolution),
         {:ok, message} <- TAT140.decode(observation),
         context = %{
           observation: observation,
           resolution: resolution,
           profile: profile,
           limits: limits,
           options: options
         },
         {:ok, records, record_evidence} <-
           record_evidence(message.records, context),
         {:ok, capability_evidence, descriptors} <-
           capability_evidence(context),
         {:ok, bundle} <-
           EvidenceBundle.new(
             [observation],
             capability_evidence ++ record_evidence,
             options
           ),
         {:ok, capabilities} <- capabilities(descriptors, bundle, options),
         {:ok, records} <- hydrate_records(records, bundle, options) do
      {:ok,
       %__MODULE__{
         bundle: bundle,
         capabilities: capabilities,
         records: records,
         resolution: resolution
       }}
    end
  end

  @doc "Re-runs the pure record import and rejects forged or stale content."
  @spec validate(term(), term(), term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(value, observation, catalogue, options \\ [])

  def validate(%__MODULE__{} = value, observation, catalogue, options) do
    with {:ok, admitted} <- run(observation, catalogue, options),
         true <- admitted === value do
      {:ok, admitted}
    else
      false -> Admission.fail(:conflict)
      error -> error
    end
  end

  def validate(_, _, _, _), do: Admission.fail(:invalid_decoder_result)

  defp exact_profile(%{status: :resolved, selected: selected}) do
    with {:ok, profile} <- TAT140.profile(), true <- selected === profile do
      {:ok, profile}
    else
      false -> {:error, Error.new(:revision_mismatch, :decode)}
      error -> error
    end
  end

  defp exact_profile(_), do: {:error, Error.new(:unknown_resolution, :decode)}

  defp record_evidence(records, context) do
    Enum.reduce_while(records, {:ok, [], []}, fn record, {:ok, records, evidence} ->
      case admit_record(record, context) do
        {:ok, admitted, claims} ->
          {:cont, {:ok, [admitted | records], Enum.reverse(claims, evidence)}}

        error ->
          {:halt, error}
      end
    end)
    |> then(fn
      {:ok, records, evidence} -> {:ok, Enum.reverse(records), Enum.reverse(evidence)}
      error -> error
    end)
  end

  defp admit_record(record, context) do
    transport_claim = %{
      "schema" => "wtr.teltonika-avl-record.v1",
      "protocol" => "teltonika-codec8-extended",
      "codec" => 0x8E,
      "index" => record.index,
      "timestamp_ms" => record.timestamp_ms,
      "priority" => Atom.to_string(record.priority),
      "trigger" => record.trigger,
      "gps" => record.gps,
      "io_elements" => record.io_elements
    }

    with {:ok, transport} <-
           evidence(
             :transport,
             transport_claim,
             [],
             "decoded_record_boundary",
             record.index,
             context
           ),
         {:ok, measurements} <-
           measurement_evidence(
             record.measurements,
             record.index,
             transport,
             context
           ),
         {:ok, positions} <-
           position_evidence(
             record.positions,
             record.index,
             transport,
             context
           ) do
      admitted = %{
        index: record.index,
        timestamp_ms: record.timestamp_ms,
        priority: record.priority,
        trigger: record.trigger,
        transport_evidence_id: transport.id,
        measurement_evidence_ids: Enum.map(measurements, & &1.id),
        position_evidence_ids: Enum.map(positions, & &1.id),
        measurements: record.measurements,
        positions: []
      }

      {:ok, admitted, [transport | measurements ++ positions]}
    end
  end

  defp measurement_evidence(measurements, index, transport, context) do
    Enum.reduce_while(measurements, {:ok, []}, fn measurement, {:ok, evidence} ->
      with {:ok, claim} <- Measurement.to_map(measurement, context.options),
           {:ok, admitted} <-
             evidence(
               :measurement,
               claim,
               [transport.id],
               "documented_io_mapping",
               {index, measurement.kind},
               context
             ) do
        {:cont, {:ok, [admitted | evidence]}}
      else
        error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, evidence} -> {:ok, Enum.reverse(evidence)}
      error -> error
    end)
  end

  defp position_evidence(positions, index, transport, context) do
    positions
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {position, ordinal}, {:ok, evidence} ->
      case evidence(
             :position,
             position,
             [transport.id],
             "documented_gnss_mapping",
             {index, ordinal},
             context
           ) do
        {:ok, admitted} -> {:cont, {:ok, [admitted | evidence]}}
        error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, evidence} -> {:ok, Enum.reverse(evidence)}
      error -> error
    end)
  end

  defp capability_evidence(context) do
    context.profile.mapping
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, [], []}, fn capability, {:ok, evidence, descriptors} ->
      with {:ok, unit} <- Map.fetch(@units, capability),
           claim = %{
             "capability" => capability,
             "unit" => unit,
             "interaction" => "property",
             "operations" => ["read"]
           },
           {:ok, admitted} <-
             evidence(
               :capability,
               claim,
               [],
               "configured_profile_mapping",
               capability,
               context
             ) do
        descriptor = %{
          id: capability,
          kind: :property,
          operations: [:read],
          unit: unit,
          evidence_ids: [admitted.id]
        }

        {:cont, {:ok, [admitted | evidence], [descriptor | descriptors]}}
      else
        :error -> {:halt, {:error, Error.new(:revision_mismatch, :decode)}}
        error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, evidence, descriptors} ->
        {:ok, Enum.reverse(evidence), Enum.reverse(descriptors)}

      error ->
        error
    end)
  end

  defp evidence(kind, claim, parents, reason, discriminator, context) do
    preimage = %{
      "schema" => "wtr.teltonika-tat140-evidence-id.v1",
      "kind" => Atom.to_string(kind),
      "claim" => claim,
      "parents" => parents,
      "discriminator" => discriminator(discriminator),
      "observation" => context.resolution.observation_identity,
      "catalogue" => context.resolution.catalogue_identity
    }

    with {:ok, id} <- Admission.digest(preimage, Limits.material(context.limits)) do
      Evidence.new(
        %{
          id: id,
          kind: kind,
          claim: claim,
          source_observation_ids: [context.observation.id],
          evidence_ids: parents,
          profile: {context.profile.id, context.profile.version},
          decoder: context.profile.decoder,
          confidence: context.profile.confidence,
          reasons: [reason],
          association_id: nil
        },
        context.options
      )
    end
  end

  defp discriminator(value) when is_tuple(value), do: Tuple.to_list(value)
  defp discriminator(value), do: value

  defp capabilities(descriptors, bundle, options) do
    Enum.reduce_while(descriptors, {:ok, []}, fn descriptor, {:ok, capabilities} ->
      case Capability.new(descriptor, bundle, options) do
        {:ok, capability} -> {:cont, {:ok, [capability | capabilities]}}
        error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, capabilities} -> {:ok, Enum.reverse(capabilities)}
      error -> error
    end)
  end

  defp hydrate_records(records, bundle, options) do
    Enum.reduce_while(records, {:ok, []}, fn record, {:ok, records} ->
      case positions(record.position_evidence_ids, bundle, options) do
        {:ok, positions} -> {:cont, {:ok, [%{record | positions: positions} | records]}}
        error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, records} -> {:ok, Enum.reverse(records)}
      error -> error
    end)
  end

  defp positions(ids, bundle, options) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, positions} ->
      case Position.new(id, bundle, options) do
        {:ok, position} -> {:cont, {:ok, [position | positions]}}
        error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, positions} -> {:ok, Enum.reverse(positions)}
      error -> error
    end)
  end
end
