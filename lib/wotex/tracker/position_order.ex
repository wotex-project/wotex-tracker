defmodule Wotex.Tracker.PositionOrder do
  @moduledoc """
  Deterministic event-time, late-arrival and modular-sequence classification.

  The classifier is pure. It identifies when a live caller may advance its head,
  when history needs ordered replay, and when sequence evidence is contradictory.
  It neither buffers observations nor mutates canonical state.
  """
  alias Wotex.Tracker.{Admission, Error, Limits, PositionSample}

  @fields ~w(revision event_time future_skew_ms late_window_ms sequence)a
  @type t :: %__MODULE__{}
  @enforce_keys @fields ++ [:identity]
  defstruct @enforce_keys

  @doc "Admits the fixed ordering, clock, lateness and sequence policy."
  @spec new(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(input, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         :ok <- Admission.fields(input, @fields),
         :ok <- Admission.id(input.revision, limits),
         true <- input.event_time in [:trusted_fix, :trusted_fix_or_receiver],
         true <- is_integer(input.future_skew_ms) and input.future_skew_ms in 0..604_800_000,
         true <- is_integer(input.late_window_ms) and input.late_window_ms in 0..604_800_000,
         true <- input.sequence in [:none, :optional, :required],
         {:ok, identity} <- Admission.digest(policy_map(input), Limits.json(limits)) do
      {:ok, struct!(__MODULE__, Map.put(input, :identity, identity))}
    else
      false -> Admission.fail(:invalid_input)
      error -> error
    end
  end

  @doc "Rejects modified policy content or a stale identity."
  @spec validate(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(value, options \\ [])

  def validate(%__MODULE__{} = policy, options) do
    with {:ok, admitted} <- new(Map.take(policy, @fields), options) do
      if admitted === policy, do: {:ok, admitted}, else: Admission.fail(:conflict)
    end
  end

  def validate(_, _), do: Admission.fail(:invalid_input)

  @doc "Classifies one sample relative to an optional previously accepted head."
  @spec evaluate(term(), term(), term(), term(), term()) :: {:ok, map()} | {:error, Error.t()}
  def evaluate(sample, previous, policy, now, options \\ []) do
    with {:ok, sample} <- PositionSample.validate(sample, options),
         {:ok, previous} <- previous(previous, options),
         {:ok, policy} <- validate(policy, options),
         true <- is_integer(now) do
      {:ok, classify(sample, previous, policy, now)}
    else
      false -> Admission.fail(:invalid_input)
      error -> error
    end
  end

  defp previous(nil, _), do: {:ok, nil}
  defp previous(value, options), do: PositionSample.validate(value, options)

  defp classify(sample, previous, policy, now) do
    current_time = event_time(sample, policy, now)
    sequence_policy = sequence_policy(sample, policy)

    cond do
      sequence_policy != :ok ->
        decision(
          sample,
          previous,
          policy,
          current_time,
          {"unknown", sequence_policy, "unknown"},
          nil
        )

      previous && previous.identity == sample.identity ->
        decision(
          sample,
          previous,
          policy,
          current_time,
          {"duplicate", "same_sample", "ignore"},
          nil
        )

      elem(current_time, 0) == :unknown ->
        decision(
          sample,
          previous,
          policy,
          current_time,
          {"unknown", elem(current_time, 1), "unknown"},
          nil
        )

      is_nil(previous) ->
        decision(
          sample,
          nil,
          policy,
          current_time,
          {"accepted", "initial", "advance"},
          sequence_start(sample)
        )

      true ->
        compare(sample, previous, policy, current_time, now)
    end
  end

  defp compare(sample, previous, policy, current_time, now) do
    previous_time = event_time(previous, policy, now)

    if elem(previous_time, 0) == :unknown do
      decision(
        sample,
        previous,
        policy,
        current_time,
        {"unknown", "previous_" <> elem(previous_time, 1), "unknown"},
        nil
      )
    else
      current_key = order_key(sample, current_time)
      previous_key = order_key(previous, previous_time)
      relation = sequence_relation(sample.sequence, previous.sequence, policy.sequence)

      cond do
        current_key > previous_key and sequence_accepted?(relation) ->
          decision(
            sample,
            previous,
            policy,
            current_time,
            {"accepted", "later_order_key", "advance"},
            relation
          )

        current_key > previous_key ->
          decision(
            sample,
            previous,
            policy,
            current_time,
            {"unknown", relation, "unknown"},
            relation
          )

        elem(current_time, 3) < elem(previous_time, 3) ->
          late = elem(previous_time, 3) - elem(current_time, 3)
          historical(sample, previous, policy, current_time, late, relation)

        true ->
          historical(sample, previous, policy, current_time, 0, relation)
      end
    end
  end

  defp historical(sample, previous, policy, current_time, late, relation) do
    if late <= policy.late_window_ms do
      decision(
        sample,
        previous,
        policy,
        current_time,
        {"historical", "within_late_window", "recompute_history"},
        relation,
        late
      )
    else
      decision(
        sample,
        previous,
        policy,
        current_time,
        {"historical", "late_window_exceeded", "history_only"},
        relation,
        late
      )
    end
  end

  defp event_time(sample, policy, now) do
    claim = sample.position.claim

    cond do
      claim["received_at"] > now + policy.future_skew_ms ->
        {:unknown, "receiver_in_future", nil, nil}

      is_integer(claim["fix_at"]) and claim["fix_clock"] != "trusted" ->
        {:unknown, "untrusted_fix_clock", nil, nil}

      is_integer(claim["fix_at"]) ->
        qualified_time(claim["fix_at"], "fix", claim["received_at"], policy, now)

      policy.event_time == :trusted_fix_or_receiver ->
        qualified_time(claim["received_at"], "receiver", claim["received_at"], policy, now)

      true ->
        {:unknown, "missing_fix_time", nil, nil}
    end
  end

  defp qualified_time(timestamp, basis, received, policy, now) do
    cond do
      timestamp > received + policy.future_skew_ms ->
        {:unknown, "fix_after_reception", basis, timestamp}

      timestamp > now + policy.future_skew_ms ->
        {:unknown, "event_in_future", basis, timestamp}

      true ->
        {:known, "qualified", basis, timestamp}
    end
  end

  defp sequence_policy(%{sequence: nil}, %{sequence: :required}), do: "missing_sequence"

  defp sequence_policy(%{sequence: sequence}, %{sequence: :none}) when not is_nil(sequence),
    do: "sequence_disabled"

  defp sequence_policy(_, _), do: :ok

  defp sequence_start(%{sequence: nil}), do: "unsequenced"
  defp sequence_start(_), do: "sequence_started"

  defp sequence_relation(_, _, :none), do: "disabled"
  defp sequence_relation(nil, nil, _), do: "unsequenced"
  defp sequence_relation(nil, _, :optional), do: "sequence_missing"
  defp sequence_relation(_, nil, _), do: "sequence_started"

  defp sequence_relation(current, previous, _) do
    cond do
      current["scope_id"] != previous["scope_id"] ->
        "distinct_scope"

      current["session_id"] != previous["session_id"] ->
        "session_reset"

      current["modulus"] != previous["modulus"] ->
        "modulus_changed"

      current["value"] == previous["value"] ->
        "sequence_conflict"

      true ->
        modular_relation(current["value"], previous["value"], current["modulus"])
    end
  end

  defp modular_relation(current, previous, modulus) do
    delta = Integer.mod(current - previous, modulus)

    cond do
      delta * 2 == modulus -> "sequence_ambiguous"
      delta * 2 < modulus and current < previous -> "sequence_wrapped"
      delta * 2 < modulus -> "sequence_advanced"
      true -> "sequence_older"
    end
  end

  defp sequence_accepted?(relation),
    do:
      relation in [
        "disabled",
        "unsequenced",
        "sequence_missing",
        "sequence_started",
        "distinct_scope",
        "session_reset",
        "sequence_advanced",
        "sequence_wrapped"
      ]

  defp order_key(sample, {_, _, _, timestamp}) do
    [
      timestamp,
      sample.position.claim["received_at"],
      sample.position.evidence_id,
      sample.position.bundle_identity,
      sample.identity
    ]
  end

  defp decision(
         sample,
         previous,
         policy,
         time,
         {status, reason, disposition},
         sequence_relation,
         late_by \\ nil
       ) do
    %{
      "schema" => "wtr.position-order.v1",
      "status" => status,
      "reason" => reason,
      "disposition" => disposition,
      "event_time_basis" => elem(time, 2),
      "event_at" => elem(time, 3),
      "received_at" => sample.position.claim["received_at"],
      "order_key" => if(elem(time, 0) == :known, do: order_key(sample, time), else: nil),
      "late_by_ms" => late_by,
      "sequence_relation" => sequence_relation,
      "sample_identity" => sample.identity,
      "position_evidence_id" => sample.position.evidence_id,
      "position_bundle_identity" => sample.position.bundle_identity,
      "previous_sample_identity" => if(previous, do: previous.identity, else: nil),
      "policy_revision" => policy.revision,
      "policy_identity" => policy.identity
    }
  end

  defp policy_map(input),
    do: %{
      "schema" => "wtr.position-order-policy.v1",
      "algorithm" => "event-time-sequence-order-v1",
      "revision" => input.revision,
      "event_time" => Atom.to_string(input.event_time),
      "future_skew_ms" => input.future_skew_ms,
      "late_window_ms" => input.late_window_ms,
      "sequence" => Atom.to_string(input.sequence)
    }
end
