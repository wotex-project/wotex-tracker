defmodule Wotex.Tracker.DeviceProfile do
  @moduledoc "Immutable profile metadata and declarative fingerprints; decoder references are inert values."
  alias Wotex.Tracker.{Admission, Error, Limits, Predicate}

  @fields ~w(id version confidence fingerprints decoder model mapping_revision mapping source_provenance)a
  @type t :: %__MODULE__{}
  @enforce_keys @fields
  defstruct @fields

  @doc "Admits a profile, refusing eligible confidence based solely on weak evidence."
  @spec new(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(input, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         :ok <- Admission.fields(input, @fields),
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
    |> Map.put("schema", "wtr.profile.v1")
  end

  defp predicates(definitions, options) do
    Enum.reduce_while(definitions, {:ok, []}, fn definition, {:ok, acc} ->
      case Predicate.new(definition, options) do
        {:ok, predicate} -> {:cont, {:ok, [predicate | acc]}}
        error -> {:halt, error}
      end
    end)
  end
end
