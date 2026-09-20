defmodule Wotex.Tracker.DeviceProfile do
  @moduledoc """
  Describes one immutable device-profile revision for catalogue resolution.

  A profile declares fingerprints, confidence, decoder and model revisions,
  mapping, source provenance and optional closed active-probe contracts. `new/2`
  rejects eligible confidence supported only by weak fingerprints and probe
  promotions that would weaken passive evidence. Decoder references are inert
  revision values here; this module does not load or execute a decoder.
  `identity/2` covers the full admitted profile document.
  """

  alias Wotex.Tracker.{Admission, Error, Limits, Predicate, ProbeContract}

  @required_fields ~w(id version confidence fingerprints decoder model mapping_revision mapping source_provenance)a
  @fields @required_fields ++ [:probes]
  @type t :: %__MODULE__{}
  @enforce_keys @required_fields
  defstruct @required_fields ++ [probes: []]

  @doc "Admits a profile, refusing eligible confidence based solely on weak evidence."
  @spec new(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(input, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         :ok <- Admission.fields(input, @required_fields, [:probes]),
         input = Map.put_new(input, :probes, []),
         :ok <- Admission.revision({input.id, input.version}, limits),
         true <- input.confidence in [:exact, :strong, :candidate, :unknown],
         :ok <- Admission.bounded_list(input.fingerprints, limits.max_predicates),
         true <- input.fingerprints != [],
         {:ok, predicates} <- predicates(input.fingerprints, options),
         true <-
           input.confidence in [:candidate, :unknown] or
             Enum.any?(predicates, &Predicate.discriminating?/1),
         :ok <- Admission.revision(input.decoder, limits),
         :ok <- Admission.revision(input.model, limits),
         :ok <- Admission.id(input.mapping_revision, limits),
         :ok <- Admission.object(input.mapping, limits),
         :ok <- Admission.object(input.source_provenance, limits),
         :ok <- Admission.bounded_list(input.probes, limits.max_predicates),
         {:ok, probes} <- probes(input.probes, input.confidence, options),
         true <- unique_probes?(probes),
         profile = struct!(__MODULE__, input),
         :ok <- Admission.json(document(profile), limits) do
      {:ok, profile}
    else
      false -> Admission.fail(:invalid_profile)
      error -> error
    end
  end

  @doc "Revalidates all fields, including a forged profile struct."
  @spec validate(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(value, options \\ [])
  def validate(%__MODULE__{} = profile, options), do: new(Map.from_struct(profile), options)
  def validate(_, _), do: Admission.fail(:invalid_profile)

  @doc "Returns the complete profile document for immutable revision identity."
  @spec to_map(term(), term()) :: {:ok, map()} | {:error, Error.t()}
  def to_map(value, options \\ []) do
    with {:ok, profile} <- validate(value, options), do: {:ok, document(profile)}
  end

  @doc "Hashes the entire profile document, including mapping and source revisions."
  @spec identity(term(), term()) :: {:ok, String.t()} | {:error, Error.t()}
  def identity(value, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         {:ok, map} <- to_map(value, options),
         do: Admission.digest(map, Limits.json(limits))
  end

  defp document(profile) do
    Map.new(@fields, &{Atom.to_string(&1), Map.fetch!(profile, &1)})
    |> Map.put("confidence", Atom.to_string(profile.confidence))
    |> Map.put("decoder", Tuple.to_list(profile.decoder))
    |> Map.put("model", Tuple.to_list(profile.model))
    |> Map.put("schema", "wtr.profile.v2")
  end

  defp predicates(definitions, options) do
    Enum.reduce_while(definitions, {:ok, []}, fn definition, {:ok, acc} ->
      case Predicate.new(definition, options) do
        {:ok, predicate} -> {:cont, {:ok, [predicate | acc]}}
        error -> {:halt, error}
      end
    end)
  end

  defp probes(definitions, confidence, options) do
    Enum.reduce_while(definitions, {:ok, []}, fn definition, {:ok, acc} ->
      with {:ok, probe} <- ProbeContract.new(definition, options),
           true <- ProbeContract.compatible_confidence?(probe, confidence) do
        {:cont, {:ok, [probe | acc]}}
      else
        false -> {:halt, Admission.fail(:invalid_profile)}
        error -> {:halt, error}
      end
    end)
  end

  defp unique_probes?(probes) do
    keys = Enum.map(probes, &ProbeContract.key/1)
    length(keys) == length(Enum.uniq(keys))
  end
end
