defmodule Wotex.Tracker.Evidence do
  @moduledoc """
  Immutable interpreted claims with explicit observation and parent-claim lineage.

  A record does not validate the truth of a claim. `EvidenceBundle` validates its
  references. Format confidence, association and authorization remain separate.
  """
  alias Wotex.Tracker.{Admission, Error, Limits}

  @fields ~w(id kind claim source_observation_ids evidence_ids profile decoder confidence reasons association_id)a
  @kinds ~w(fingerprint identity capability measurement position transport)a
  @confidences ~w(exact strong candidate unknown)a
  @type t :: %__MODULE__{}
  @enforce_keys @fields
  defstruct @fields

  @doc "Admits a bounded claim and its declared revisions and references."
  @spec new(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(input, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         :ok <- Admission.fields(input, @fields),
         :ok <- Admission.id(input.id, limits),
         true <- input.kind in @kinds and input.confidence in @confidences,
         :ok <- Admission.object(input.claim, limits),
         :ok <- Admission.ids(input.source_observation_ids, limits, limits.max_sources),
         true <- input.source_observation_ids != [],
         :ok <- Admission.ids(input.evidence_ids, limits, limits.max_sources),
         :ok <- Admission.revision(input.profile, limits),
         :ok <- Admission.revision(input.decoder, limits),
         :ok <- Admission.ids(input.reasons, limits, 32),
         :ok <- association(input.association_id, limits) do
      {:ok, struct!(__MODULE__, input)}
    else
      false -> Admission.fail(:invalid_input)
      error -> error
    end
  end

  @doc "Validates every field behind an evidence struct tag."
  @spec validate(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(value, options \\ [])
  def validate(%__MODULE__{} = value, options), do: new(Map.from_struct(value), options)
  def validate(_, _), do: Admission.fail(:invalid_input)

  @doc "Exports a revalidated evidence record without changing native claim types."
  @spec to_map(term(), term()) :: {:ok, map()} | {:error, Error.t()}
  def to_map(value, options \\ []) do
    with {:ok, evidence} <- validate(value, options) do
      map = Map.new(@fields, &{Atom.to_string(&1), Map.fetch!(evidence, &1)})

      {:ok,
       map
       |> Map.put("kind", Atom.to_string(evidence.kind))
       |> Map.put("confidence", Atom.to_string(evidence.confidence))
       |> Map.put("profile", Tuple.to_list(evidence.profile))
       |> Map.put("decoder", Tuple.to_list(evidence.decoder))
       |> Map.put("schema", "wtr.evidence.v1")}
    end
  end

  defp association(nil, _), do: :ok
  defp association(id, limits), do: Admission.id(id, limits)
end
