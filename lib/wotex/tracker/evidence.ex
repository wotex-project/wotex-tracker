defmodule Wotex.Tracker.Evidence do
  @moduledoc """
  Immutable interpreted claims with explicit observation and parent-claim lineage.

  A record does not validate the truth of a claim. `EvidenceBundle` validates its
  references. Format confidence, association and authorization remain separate.
  """
  alias Wotex.Tracker.{Admission, Error, Limits}

  @fields ~w(id kind claim source_observation_ids evidence_ids profile decoder confidence reasons association_id)a
  @serialized_fields ~w(schema id kind claim source_observation_ids evidence_ids profile decoder confidence reasons association_id)
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

  @doc "Admits a closed native-JSON evidence export without creating atoms."
  @spec from_map(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(map, options \\ []) do
    with true <- exact_fields?(map, @serialized_fields),
         true <- map["schema"] == "wtr.evidence.v1",
         {:ok, kind} <- kind(map["kind"]),
         {:ok, confidence} <- confidence(map["confidence"]),
         {:ok, profile} <- revision(map["profile"]),
         {:ok, decoder} <- revision(map["decoder"]) do
      new(
        %{
          id: map["id"],
          kind: kind,
          claim: map["claim"],
          source_observation_ids: map["source_observation_ids"],
          evidence_ids: map["evidence_ids"],
          profile: profile,
          decoder: decoder,
          confidence: confidence,
          reasons: map["reasons"],
          association_id: map["association_id"]
        },
        options
      )
    else
      false -> Admission.fail(:invalid_input)
      error -> error
    end
  end

  defp kind("fingerprint"), do: {:ok, :fingerprint}
  defp kind("identity"), do: {:ok, :identity}
  defp kind("capability"), do: {:ok, :capability}
  defp kind("measurement"), do: {:ok, :measurement}
  defp kind("position"), do: {:ok, :position}
  defp kind("transport"), do: {:ok, :transport}
  defp kind(_), do: Admission.fail(:invalid_input)

  defp confidence("exact"), do: {:ok, :exact}
  defp confidence("strong"), do: {:ok, :strong}
  defp confidence("candidate"), do: {:ok, :candidate}
  defp confidence("unknown"), do: {:ok, :unknown}
  defp confidence(_), do: Admission.fail(:invalid_input)

  defp revision([id, version]) when is_binary(id) and is_binary(version),
    do: {:ok, {id, version}}

  defp revision(_), do: Admission.fail(:invalid_input)

  defp exact_fields?(value, fields),
    do:
      is_map(value) and not is_struct(value) and
        Enum.sort(Map.keys(value)) == Enum.sort(fields)

  defp association(nil, _), do: :ok
  defp association(id, limits), do: Admission.id(id, limits)
end
