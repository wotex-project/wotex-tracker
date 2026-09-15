defmodule Wotex.Tracker.PositionSelection do
  @moduledoc """
  Deterministic selection of one qualified position from immutable evidence.

  Selection re-evaluates freshness from each position and bundle. Callers cannot
  supply a forged freshness label. The result records the complete ordered rank,
  policy identities and rejected-candidate reasons; it performs no fusion.
  """
  alias Wotex.Tracker.{Admission, Error, EvidenceBundle, Limits, Position, PositionFreshness}

  @fields ~w(revision accepted_freshness source_priority unlisted_sources missing_accuracy max_horizontal_accuracy_m)a
  @sources ~w(gnss cellular wifi ble lorawan operator)a
  @freshness ~w(fresh stale)a
  @type t :: %__MODULE__{}
  @enforce_keys @fields ++ [:identity]
  defstruct @enforce_keys

  @doc "Admits a closed selection policy and binds every decision field to its identity."
  @spec new(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(input, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         :ok <- Admission.fields(input, @fields),
         :ok <- Admission.id(input.revision, limits),
         :ok <- ordered_subset(input.accepted_freshness, @freshness, 2),
         :ok <- ordered_subset(input.source_priority, @sources, 6),
         true <- input.unlisted_sources in [:reject, :last],
         true <- input.missing_accuracy in [:reject, :first, :last],
         true <- accuracy_limit?(input.max_horizontal_accuracy_m),
         {:ok, identity} <- Admission.digest(policy_map(input), Limits.json(limits)) do
      {:ok, struct!(__MODULE__, Map.put(input, :identity, identity))}
    else
      false -> Admission.fail(:invalid_input)
      error -> error
    end
  end

  @doc "Rejects a forged or modified policy identity."
  @spec validate(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(value, options \\ [])

  def validate(%__MODULE__{} = policy, options) do
    with {:ok, admitted} <- new(Map.take(policy, @fields), options) do
      if admitted === policy, do: {:ok, admitted}, else: Admission.fail(:conflict)
    end
  end

  def validate(_, _), do: Admission.fail(:invalid_input)

  @doc "Selects one position or returns a reasoned unknown result without reading a clock."
  @spec select(term(), term(), term(), term(), term()) :: {:ok, map()} | {:error, Error.t()}
  def select(candidates, policy, freshness_policy, now, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         :ok <- Admission.bounded_list(candidates, limits.max_sources),
         {:ok, policy} <- validate(policy, options),
         {:ok, freshness_policy} <- PositionFreshness.validate(freshness_policy, options),
         true <- is_integer(now),
         {:ok, ranked, rejected} <- rank(candidates, policy, freshness_policy, now, options),
         :ok <- unique_candidates(ranked, rejected) do
      {:ok, result(ranked, rejected, policy, freshness_policy, now)}
    else
      false -> Admission.fail(:invalid_input)
      error -> error
    end
  end

  defp rank(candidates, policy, freshness_policy, now, options) do
    Enum.reduce_while(candidates, {:ok, [], []}, fn candidate, {:ok, ranked, rejected} ->
      case candidate(candidate, policy, freshness_policy, now, options) do
        {:ok, {:ranked, value}} -> {:cont, {:ok, [value | ranked], rejected}}
        {:ok, {:rejected, value}} -> {:cont, {:ok, ranked, [value | rejected]}}
        error -> {:halt, error}
      end
    end)
  end

  defp candidate(candidate, policy, freshness_policy, now, options) do
    with :ok <- Admission.fields(candidate, ~w(position bundle)a),
         {:ok, bundle} <- EvidenceBundle.validate(candidate.bundle, options),
         {:ok, position} <- Position.validate(candidate.position, bundle, options),
         {:ok, freshness} <-
           PositionFreshness.evaluate(position, bundle, freshness_policy, now, options) do
      admit(position, freshness, policy)
    end
  end

  defp admit(position, freshness, policy) do
    claim = position.claim

    cond do
      freshness["status"] not in Enum.map(policy.accepted_freshness, &Atom.to_string/1) ->
        rejected(position, "freshness:" <> freshness["status"])

      source_rank(claim["source"], policy) == :reject ->
        rejected(position, "unlisted_source")

      accuracy_rank(claim["horizontal_accuracy_m"], policy) == :reject ->
        rejected(position, "missing_accuracy")

      exceeds_accuracy?(claim["horizontal_accuracy_m"], policy.max_horizontal_accuracy_m) ->
        rejected(position, "accuracy_limit")

      true ->
        rank = [
          index(policy.accepted_freshness, freshness_atom(freshness["status"])),
          source_rank(claim["source"], policy),
          if(claim["quality"] == "valid", do: 0, else: 1),
          accuracy_rank(claim["horizontal_accuracy_m"], policy),
          -freshness["timestamp"],
          -claim["received_at"],
          position.evidence_id,
          position.bundle_identity
        ]

        {:ok, {:ranked, %{position: position, freshness: freshness, rank: rank}}}
    end
  end

  defp rejected(position, reason),
    do:
      {:ok,
       {:rejected,
        %{
          "evidence_id" => position.evidence_id,
          "bundle_identity" => position.bundle_identity,
          "reason" => reason
        }}}

  defp result([], rejected, policy, freshness_policy, now) do
    %{
      "schema" => "wtr.position-selection.v1",
      "status" => "unknown",
      "reason" => "no_qualified_position",
      "selected" => nil,
      "qualified_count" => 0,
      "rejected" => rejected |> Enum.reverse() |> Enum.sort_by(&rejected_key/1),
      "evaluated_at" => now,
      "policy_revision" => policy.revision,
      "policy_identity" => policy.identity,
      "freshness_policy_revision" => freshness_policy.revision,
      "freshness_policy_identity" => freshness_policy.identity
    }
  end

  defp result(ranked, rejected, policy, freshness_policy, now) do
    ordered = Enum.sort_by(ranked, & &1.rank)
    best = hd(ordered)

    %{
      "schema" => "wtr.position-selection.v1",
      "status" => "selected",
      "reason" => "deterministic_rank",
      "selected" => selected(best),
      "qualified_count" => length(ordered),
      "rejected" => rejected |> Enum.reverse() |> Enum.sort_by(&rejected_key/1),
      "evaluated_at" => now,
      "policy_revision" => policy.revision,
      "policy_identity" => policy.identity,
      "freshness_policy_revision" => freshness_policy.revision,
      "freshness_policy_identity" => freshness_policy.identity
    }
  end

  defp selected(value) do
    claim = value.position.claim

    %{
      "evidence_id" => value.position.evidence_id,
      "bundle_identity" => value.position.bundle_identity,
      "source" => claim["source"],
      "quality" => claim["quality"],
      "horizontal_accuracy_m" => claim["horizontal_accuracy_m"],
      "fix_at" => claim["fix_at"],
      "received_at" => claim["received_at"],
      "freshness" => value.freshness,
      "rank" => value.rank
    }
  end

  defp ordered_subset(values, allowed, maximum) do
    with :ok <- Admission.bounded_list(values, maximum),
         true <- values != [] and Enum.all?(values, &(&1 in allowed)),
         true <- Enum.uniq(values) == values do
      :ok
    else
      false -> Admission.fail(:invalid_input)
      error -> error
    end
  end

  defp accuracy_limit?(nil), do: true
  defp accuracy_limit?(value), do: is_number(value) and value >= 0 and value <= 40_100_000

  defp source_rank(source, policy) do
    case Enum.find_index(policy.source_priority, &(Atom.to_string(&1) == source)) do
      nil when policy.unlisted_sources == :reject -> :reject
      nil -> length(policy.source_priority)
      rank -> rank
    end
  end

  defp accuracy_rank(nil, %{missing_accuracy: :reject}), do: :reject
  defp accuracy_rank(nil, %{missing_accuracy: :first}), do: -1
  defp accuracy_rank(nil, %{missing_accuracy: :last}), do: 40_100_001
  defp accuracy_rank(value, _), do: value

  defp exceeds_accuracy?(_, nil), do: false
  defp exceeds_accuracy?(nil, _), do: false
  defp exceeds_accuracy?(value, maximum), do: value > maximum

  defp unique_candidates(ranked, rejected) do
    keys =
      Enum.map(ranked, &{&1.position.evidence_id, &1.position.bundle_identity}) ++
        Enum.map(rejected, &rejected_key/1)

    if Enum.uniq(keys) == keys, do: :ok, else: Admission.fail(:duplicate_id)
  end

  defp rejected_key(value), do: {value["evidence_id"], value["bundle_identity"]}

  defp index(values, value), do: Enum.find_index(values, &(&1 == value))
  defp freshness_atom("fresh"), do: :fresh
  defp freshness_atom("stale"), do: :stale

  defp policy_map(input),
    do: %{
      "schema" => "wtr.position-selection-policy.v1",
      "algorithm" => "freshness-source-quality-accuracy-time-id-v1",
      "revision" => input.revision,
      "accepted_freshness" => Enum.map(input.accepted_freshness, &Atom.to_string/1),
      "source_priority" => Enum.map(input.source_priority, &Atom.to_string/1),
      "unlisted_sources" => Atom.to_string(input.unlisted_sources),
      "missing_accuracy" => Atom.to_string(input.missing_accuracy),
      "max_horizontal_accuracy_m" => input.max_horizontal_accuracy_m
    }
end
