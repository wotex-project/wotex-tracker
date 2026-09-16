defmodule Wotex.Tracker.HeartbeatTransitionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Wotex.Tracker.{Fixtures, HeartbeatTransition}

  test "threshold equality is current and the next millisecond emits one overdue event" do
    policy = policy(%{maximum_silence_ms: 10})
    heartbeat = observation("heartbeat", 1_000)

    assert {:ok, baseline} =
             HeartbeatTransition.evaluate(nil, heartbeat, policy, :live, 1_010)

    assert baseline["status"] == "baseline"
    assert baseline["heartbeat_status"] == "current"
    assert baseline["age_ms"] == 10
    assert baseline["due_at"] == 1_011
    assert baseline["event"] == nil

    assert {:ok, overdue} =
             HeartbeatTransition.evaluate(baseline["state"], nil, policy, :live, 1_011)

    assert overdue["status"] == "transition"
    assert overdue["heartbeat_status"] == "overdue"
    assert overdue["event"]["kind"] == "heartbeat.overdue"
    assert overdue["event"]["event_at"] == 1_011
    assert overdue["event"]["from_observation_id"] == "heartbeat"
    assert overdue["physical_action_dispatch"] == "separate_authorization_required"

    assert {:ok, ^overdue} =
             HeartbeatTransition.validate_transition(baseline["state"], overdue)

    assert :ok = HeartbeatTransition.validate_event(overdue["event"])
    assert {:ok, document} = HeartbeatTransition.state_to_map(overdue["state"])
    assert {:ok, restored} = HeartbeatTransition.state_from_map(document)
    assert restored === overdue["state"]
    assert {:ok, policy_document} = HeartbeatTransition.to_map(policy)
    assert HeartbeatTransition.from_map(policy_document) == {:ok, policy}

    assert {:ok, repeated} =
             HeartbeatTransition.evaluate(overdue["state"], nil, policy, :live, 1_012)

    assert repeated["status"] == "stable"
    assert repeated["event"] == nil
    assert repeated["heartbeat_status"] == "overdue"
  end

  test "a newer heartbeat recovers overdue state with stable evidence identity" do
    policy = policy(%{maximum_silence_ms: 10})
    old = observation("old", 1_000)
    fresh = observation("fresh", 1_020)
    {:ok, baseline} = HeartbeatTransition.evaluate(nil, old, policy, :live, 1_000)
    {:ok, overdue} = HeartbeatTransition.evaluate(baseline["state"], nil, policy, :live, 1_011)

    assert {:ok, live} =
             HeartbeatTransition.evaluate(overdue["state"], fresh, policy, :live, 1_020)

    assert live["heartbeat_status"] == "current"
    assert live["event"]["kind"] == "heartbeat.recovered"
    assert live["event"]["event_at"] == 1_020
    assert live["event"]["to_observation_id"] == "fresh"

    assert {:ok, replay} =
             HeartbeatTransition.evaluate(overdue["state"], fresh, policy, :replay, 1_020)

    assert replay["state"] === live["state"]
    assert replay["event"] === live["event"]
    assert replay["physical_action_dispatch"] == "prohibited"
  end

  test "initial overdue evidence is a baseline and a missing initial tick is unknown" do
    policy = policy()

    assert {:ok, missing} = HeartbeatTransition.evaluate(nil, nil, policy, :live, 1_000)
    assert missing["status"] == "unknown"
    assert missing["reason"] == "missing_observation"
    assert missing["state"] == nil

    assert {:ok, baseline} =
             HeartbeatTransition.evaluate(
               nil,
               observation("old", 0),
               policy,
               :live,
               100_000
             )

    assert baseline["status"] == "baseline"
    assert baseline["heartbeat_status"] == "overdue"
    assert baseline["event"] == nil
  end

  test "future skew and caller clock regression fail without changing canonical state" do
    policy = policy(%{future_skew_ms: 5})
    baseline_observation = observation("baseline", 1_000)

    {:ok, baseline} =
      HeartbeatTransition.evaluate(nil, baseline_observation, policy, :live, 1_000)

    within_skew = observation("within-skew", 1_005)

    assert {:ok, accepted} =
             HeartbeatTransition.evaluate(
               baseline["state"],
               within_skew,
               policy,
               :live,
               1_000
             )

    assert accepted["observation_outcome"] == "accepted"
    assert accepted["age_ms"] == -5

    too_far = observation("too-far", 1_006)

    assert {:ok, future} =
             HeartbeatTransition.evaluate(
               baseline["state"],
               too_far,
               policy,
               :live,
               1_000
             )

    assert future["reason"] == "observation_in_future"
    assert future["state"] === baseline["state"]

    assert {:ok, regressed} =
             HeartbeatTransition.evaluate(
               baseline["state"],
               nil,
               policy,
               :live,
               999
             )

    assert regressed["reason"] == "clock_regressed"
    assert regressed["state"] === baseline["state"]
  end

  test "historical and duplicate observations never replace the heartbeat head" do
    policy = policy(%{maximum_silence_ms: 10})
    current = observation("current", 1_000)
    historical = observation("historical", 900)
    {:ok, baseline} = HeartbeatTransition.evaluate(nil, current, policy, :live, 1_000)

    assert {:ok, result} =
             HeartbeatTransition.evaluate(
               baseline["state"],
               historical,
               policy,
               :live,
               1_011
             )

    assert result["observation_outcome"] == "historical"
    assert result["state"].observation.id == "current"
    assert result["event"]["kind"] == "heartbeat.overdue"

    assert {:ok, duplicate} =
             HeartbeatTransition.evaluate(
               baseline["state"],
               current,
               policy,
               :live,
               1_001
             )

    assert duplicate["observation_outcome"] == "duplicate"
    assert duplicate["event"] == nil

    conflicting = %{current | radio: %{"rssi" => -99}}

    assert {:error, %{code: :conflict}} =
             HeartbeatTransition.evaluate(
               baseline["state"],
               conflicting,
               policy,
               :live,
               1_001
             )
  end

  test "rule revision emits recomputation rather than an overdue or recovery transition" do
    original = policy(%{maximum_silence_ms: 100})
    revised = policy(%{revision: "heartbeat-v2", maximum_silence_ms: 10})
    heartbeat = observation("heartbeat", 1_000)
    {:ok, baseline} = HeartbeatTransition.evaluate(nil, heartbeat, original, :live, 1_000)

    assert {:ok, result} =
             HeartbeatTransition.evaluate(
               baseline["state"],
               nil,
               revised,
               :live,
               1_011
             )

    assert result["status"] == "recomputed"
    assert result["heartbeat_status"] == "overdue"
    assert result["event"]["kind"] == "heartbeat.recomputed"
    assert result["event"]["from_status"] == "current"
    assert result["event"]["to_status"] == "overdue"

    other_scope = policy(%{id: "other"})

    assert {:error, %{code: :conflict}} =
             HeartbeatTransition.evaluate(
               baseline["state"],
               nil,
               other_scope,
               :live,
               1_001
             )
  end

  test "policy and state identity reject every mutated deadline input" do
    original = policy()

    for change <- [
          %{id: "other"},
          %{revision: "other"},
          %{maximum_silence_ms: 2_000},
          %{future_skew_ms: 1}
        ] do
      changed = policy(change)
      refute changed.identity == original.identity
      assert {:error, %{code: :conflict}} = HeartbeatTransition.validate(struct(original, change))
    end

    for change <- [
          %{id: ""},
          %{revision: ""},
          %{maximum_silence_ms: -1},
          %{maximum_silence_ms: 604_800_001},
          %{future_skew_ms: -1},
          %{extra: true}
        ] do
      assert {:error, _} = HeartbeatTransition.new(Map.merge(policy_input(), change))
    end

    heartbeat = observation("heartbeat", 1_000)
    {:ok, baseline} = HeartbeatTransition.evaluate(nil, heartbeat, original, :live, 1_000)

    assert {:error, %{code: :conflict}} =
             HeartbeatTransition.validate_state(%{baseline["state"] | due_at: 1_001})

    assert {:error, %{code: :conflict}} =
             HeartbeatTransition.validate_state(%{baseline["state"] | identity: "forged"})

    assert {:ok, document} = HeartbeatTransition.state_to_map(baseline["state"])

    for changed <- [
          Map.put(document, "status", "overdue"),
          Map.put(document, "due_at", 0),
          Map.put(document, "evaluated_at", "1000"),
          Map.put(document, "identity", "forged"),
          put_in(document, ["policy", "identity"], "forged"),
          put_in(document, ["observation", "radio"], %{"rssi" => -99}),
          Map.put(document, "extra", true)
        ] do
      assert {:error, _} = HeartbeatTransition.state_from_map(changed)
    end

    {:ok, overdue} =
      HeartbeatTransition.evaluate(baseline["state"], nil, original, :live, 2_001)

    assert {:error, _} =
             HeartbeatTransition.validate_transition(
               baseline["state"],
               put_in(overdue, ["event", "reason"], "changed")
             )

    assert {:error, _} =
             HeartbeatTransition.validate_event(Map.put(overdue["event"], "extra", true))

    assert {:error, _} = HeartbeatTransition.validate_state(:invalid)
    assert {:error, _} = HeartbeatTransition.new(nil)
    assert {:error, _} = HeartbeatTransition.validate(:invalid)

    assert {:error, _} =
             HeartbeatTransition.evaluate(nil, heartbeat, original, :invalid, 1_000)
  end

  property "the first overdue millisecond is exact for every admitted silence threshold" do
    check all(threshold <- integer(0..100_000), observed_at <- integer(-100_000..100_000)) do
      policy = policy(%{maximum_silence_ms: threshold})
      heartbeat = observation("heartbeat-#{threshold}-#{observed_at}", observed_at)

      {:ok, baseline} =
        HeartbeatTransition.evaluate(nil, heartbeat, policy, :replay, observed_at + threshold)

      assert baseline["heartbeat_status"] == "current"

      {:ok, overdue} =
        HeartbeatTransition.evaluate(
          baseline["state"],
          nil,
          policy,
          :replay,
          observed_at + threshold + 1
        )

      assert overdue["heartbeat_status"] == "overdue"
      assert overdue["event"]["event_at"] == observed_at + threshold + 1
    end
  end

  defp policy(changes \\ %{}) do
    {:ok, value} = HeartbeatTransition.new(Map.merge(policy_input(), changes))
    value
  end

  defp policy_input,
    do: %{
      id: "heartbeat-rule",
      revision: "heartbeat-v1",
      maximum_silence_ms: 1_000,
      future_skew_ms: 0
    }

  defp observation(id, observed_at),
    do: Fixtures.observation(%{id: id, observed_at: observed_at})
end
