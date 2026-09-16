defmodule Wotex.Tracker.MotionTransitionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Wotex.Tracker.{
    Evidence,
    EvidenceBundle,
    Fixtures,
    MotionTransition,
    Position,
    PositionMovement,
    PositionOrder,
    PositionSample
  }

  test "consecutive moving and stationary evidence starts and stops one trip at dwell equality" do
    policy = policy()
    first = sample("first", 0, 0, 0)
    moving_one = sample("moving-one", 0, 0.0001, 1_000)
    moving_two = sample("moving-two", 0, 0.0002, 2_000)
    stopped_one = sample("stopped-one", 0, 0.0002, 3_000)
    stopped_two = sample("stopped-two", 0, 0.0002, 4_000)

    {:ok, baseline} = MotionTransition.evaluate(nil, first, policy, :live, 0)
    assert baseline["status"] == "baseline"
    assert baseline["motion_status"] == "unknown"

    {:ok, candidate} =
      MotionTransition.evaluate(baseline["state"], moving_one, policy, :live, 1_000)

    assert candidate["status"] == "pending"
    assert candidate["candidate_status"] == "moving"
    assert candidate["event"] == nil

    {:ok, started} =
      MotionTransition.evaluate(candidate["state"], moving_two, policy, :live, 2_000)

    assert started["status"] == "transition"
    assert started["motion_status"] == "moving"
    assert started["event"]["kind"] == "trip.started"
    assert started["event"]["effective_at"] == 1_000
    assert started["event"]["confirmed_at"] == 2_000
    assert started["event"]["trip_id"] == started["active_trip"].id
    assert started["physical_action_dispatch"] == "separate_authorization_required"

    {:ok, stopping} =
      MotionTransition.evaluate(started["state"], stopped_one, policy, :live, 3_000)

    assert stopping["status"] == "pending"
    assert stopping["motion_status"] == "moving"
    assert stopping["candidate_status"] == "stationary"
    assert stopping["active_trip"].id == started["active_trip"].id

    {:ok, stopped} =
      MotionTransition.evaluate(stopping["state"], stopped_two, policy, :live, 4_000)

    assert stopped["motion_status"] == "stationary"
    assert stopped["active_trip"] == nil
    assert stopped["event"]["kind"] == "trip.stopped"
    assert stopped["event"]["trip_id"] == started["active_trip"].id
    assert stopped["event"]["effective_at"] == 3_000
    assert stopped["event"]["confirmed_at"] == 4_000
  end

  test "one segment and a fluctuating class cannot establish a trip" do
    policy = policy(%{minimum_movement_ms: 1})
    first = sample("first", 0, 0, 0)
    spike = sample("spike", 0, 0.01, 10_000)
    settled = sample("settled", 0, 0.01, 11_000)
    moving = sample("moving", 0, 0.0101, 12_000)

    {:ok, baseline} = MotionTransition.evaluate(nil, first, policy, :live, 0)
    {:ok, pending} = MotionTransition.evaluate(baseline["state"], spike, policy, :live, 10_000)
    assert pending["status"] == "pending"
    assert pending["active_trip"] == nil

    {:ok, changed} =
      MotionTransition.evaluate(pending["state"], settled, policy, :live, 11_000)

    assert changed["candidate_status"] == "stationary"
    assert changed["motion_status"] == "unknown"
    assert changed["event"] == nil

    {:ok, changed_again} =
      MotionTransition.evaluate(changed["state"], moving, policy, :live, 12_000)

    assert changed_again["candidate_status"] == "moving"
    assert changed_again["event"] == nil
  end

  test "closed policy, sample, state and event documents restore exact motion content" do
    policy = policy()
    first = sample("serialized-first", 0, 0, 0)
    second = sample("serialized-second", 0, 0.0001, 1_000)
    third = sample("serialized-third", 0, 0.0002, 2_000)

    {:ok, baseline} = MotionTransition.evaluate(nil, first, policy, :live, 0)

    {:ok, candidate} =
      MotionTransition.evaluate(baseline["state"], second, policy, :live, 1_000)

    {:ok, started} =
      MotionTransition.evaluate(candidate["state"], third, policy, :live, 2_000)

    {:ok, replay_started} =
      MotionTransition.evaluate(candidate["state"], third, policy, :replay, 2_000)

    assert {:ok, ^started} =
             MotionTransition.validate_transition(candidate["state"], started)

    assert {:ok, ^replay_started} =
             MotionTransition.validate_transition(candidate["state"], replay_started)

    assert {:ok, ^candidate} =
             MotionTransition.validate_transition(baseline["state"], candidate)

    assert :ok = MotionTransition.validate_event(started["event"])
    assert {:ok, policy_document} = MotionTransition.to_map(policy)
    assert MotionTransition.from_map(policy_document) == {:ok, policy}
    assert {:ok, sample_document} = PositionSample.to_map(third)
    assert PositionSample.from_map(sample_document) == {:ok, third}
    assert {:ok, candidate_document} = MotionTransition.state_to_map(candidate["state"])

    assert MotionTransition.state_from_map(candidate_document) ==
             {:ok, candidate["state"]}

    assert {:ok, state_document} = MotionTransition.state_to_map(started["state"])
    assert length(state_document["samples"]) == 2
    assert MotionTransition.state_from_map(state_document) == {:ok, started["state"]}

    for changed <- [
          Map.put(state_document, "identity", "forged"),
          put_in(state_document, ["policy", "identity"], "forged"),
          put_in(state_document, ["samples", Access.at(0), "identity"], "forged"),
          put_in(state_document, ["active_trip", "trip_id"], "forged"),
          Map.put(state_document, "order_sample_identity", "missing"),
          Map.put(state_document, "order_sample_identity", nil),
          Map.update!(state_document, "samples", &(&1 ++ &1)),
          Map.put(state_document, "samples", List.duplicate(sample_document, 7)),
          Map.put(state_document, "schema", "wtr.motion-state.v2"),
          Map.put(state_document, "extra", true)
        ] do
      assert {:error, _} = MotionTransition.state_from_map(changed)
    end

    order_document = policy_document["movement_policy"]["order_policy"]
    movement_document = policy_document["movement_policy"]

    for changed <- [
          Map.put(policy_document, "schema", "wtr.motion-transition-policy.v2"),
          put_in(policy_document, ["movement_policy", "identity"], "forged"),
          Map.put(policy_document, "identity", "forged"),
          Map.put(policy_document, "extra", true)
        ] do
      assert {:error, _} = MotionTransition.from_map(changed)
    end

    for changed <- [
          Map.put(movement_document, "uncertainty", "guessed"),
          Map.put(movement_document, "uncertainty", "require_bound"),
          Map.put(movement_document, "order_policy_identity", "forged"),
          Map.put(movement_document, "extra", true)
        ] do
      assert {:error, _} = PositionMovement.from_map(changed)
    end

    for changed <- [
          Map.put(order_document, "event_time", "receiver_only"),
          Map.put(order_document, "event_time", "trusted_fix_or_receiver"),
          Map.put(order_document, "sequence", "invented"),
          Map.put(order_document, "sequence", "optional"),
          Map.put(order_document, "sequence", "required"),
          Map.put(order_document, "identity", "forged"),
          Map.put(order_document, "extra", true)
        ] do
      assert {:error, _} = PositionOrder.from_map(changed)
    end

    for changed <- [
          Map.put(sample_document, "schema", "wtr.position-sample.v2"),
          Map.put(sample_document, "received_at", -1),
          Map.put(sample_document, "extra", true)
        ] do
      assert {:error, _} = PositionSample.from_map(changed)
    end

    assert {:error, _} =
             MotionTransition.validate_transition(
               candidate["state"],
               put_in(started, ["event", "reason"], "changed")
             )

    assert {:error, _} =
             MotionTransition.validate_event(Map.put(started["event"], "extra", true))

    for changed <- [
          Map.put(started["event"], "schema", "wtr.trip-event.v2"),
          Map.put(started["event"], "kind", "trip.guessed"),
          Map.put(started["event"], "confirmed_at", 0),
          Map.put(started["event"], "id", "forged")
        ] do
      assert {:error, _} = MotionTransition.validate_event(changed)
    end

    assert {:error, _} = MotionTransition.validate_transition(nil, nil)

    assert {:error, _} =
             MotionTransition.validate_transition(
               candidate["state"],
               Map.put(started, "mode", "invented")
             )
  end

  test "initial stationary evidence becomes a baseline without inventing a stop event" do
    policy = policy()
    first = sample("first", 1, 1, 0)
    second = sample("second", 1, 1, 1_000)
    third = sample("third", 1, 1, 2_000)

    {:ok, baseline} = MotionTransition.evaluate(nil, first, policy, :live, 0)
    {:ok, pending} = MotionTransition.evaluate(baseline["state"], second, policy, :live, 1_000)
    {:ok, stationary} = MotionTransition.evaluate(pending["state"], third, policy, :live, 2_000)

    assert stationary["status"] == "baseline"
    assert stationary["reason"] == "stationary_dwell_met"
    assert stationary["motion_status"] == "stationary"
    assert stationary["event"] == nil
  end

  test "a classified gap interrupts a trip and reestablishes a segment baseline" do
    policy = policy(%{movement_policy: movement_policy(%{max_gap_ms: 1_000})})
    started = started_trip(policy)
    after_gap = sample("after-gap", 0, 0.0003, 4_001)

    {:ok, interrupted} =
      MotionTransition.evaluate(started["state"], after_gap, policy, :live, 4_001)

    assert interrupted["status"] == "transition"
    assert interrupted["reason"] == "time_gap_exceeded"
    assert interrupted["event"]["kind"] == "trip.interrupted"
    assert interrupted["event"]["trip_id"] == started["active_trip"].id
    assert interrupted["motion_status"] == "unknown"
    assert interrupted["active_trip"] == nil
    assert interrupted["state"].segment_sample.identity == after_gap.identity

    next = sample("next", 0, 0.0004, 5_001)

    {:ok, pending} =
      MotionTransition.evaluate(interrupted["state"], next, policy, :live, 5_001)

    assert pending["status"] == "pending"
    assert pending["event"] == nil
  end

  test "implausible movement is rejected as a segment baseline and interrupts an active trip" do
    policy = policy(%{movement_policy: movement_policy(%{max_plausible_speed_m_s: 100})})
    started = started_trip(policy)
    impossible = sample("impossible", 0, 1, 2_001)

    {:ok, interrupted} =
      MotionTransition.evaluate(started["state"], impossible, policy, :live, 2_001)

    assert interrupted["classification"]["status"] == "implausible"
    assert interrupted["event"]["kind"] == "trip.interrupted"
    assert interrupted["motion_status"] == "unknown"
    assert interrupted["state"].segment_sample == nil

    recovered = sample("recovered", 0, 1.0001, 3_001)

    {:ok, baseline} =
      MotionTransition.evaluate(interrupted["state"], recovered, policy, :live, 3_001)

    assert baseline["status"] == "baseline"
    assert baseline["reason"] == "segment_baseline_reestablished"
    assert baseline["classification"] == nil
  end

  test "indeterminate evidence clears dwell without closing a confirmed trip" do
    movement =
      movement_policy(%{
        moving_speed_m_s: 20,
        stationary_speed_m_s: 1,
        moving_distance_m: 20,
        stationary_distance_m: 1
      })

    policy = policy(%{movement_policy: movement})
    started = started_trip(policy, 0.001)
    indeterminate = sample("indeterminate", 0, 0.0021, 3_000)

    {:ok, result} =
      MotionTransition.evaluate(started["state"], indeterminate, policy, :live, 3_000)

    assert result["status"] == "indeterminate"
    assert result["motion_status"] == "moving"
    assert result["candidate_status"] == nil
    assert result["active_trip"].id == started["active_trip"].id
    assert result["event"] == nil
  end

  test "historical reception advances last-received state without changing canonical motion" do
    policy = policy()
    started = started_trip(policy)
    late = sample("late", 0, 0, 999, received_at: 5_000)

    {:ok, historical} =
      MotionTransition.evaluate(started["state"], late, policy, :live, 5_000)

    assert historical["status"] == "historical"
    assert historical["event"] == nil
    assert historical["state"].order_sample.identity == started["state"].order_sample.identity
    assert historical["state"].last_received_sample.identity == late.identity
    assert historical["state"].last_received_outcome == "historical"
    assert historical["active_trip"].id == started["active_trip"].id
  end

  test "rule revision resets dwell and explicitly interrupts an active trip" do
    original = policy()
    started = started_trip(original)
    revised = policy(%{revision: "motion-rule-v2"})

    {:ok, result} =
      MotionTransition.evaluate(
        started["state"],
        started["state"].order_sample,
        revised,
        :live,
        2_000
      )

    assert result["status"] == "recomputed"
    assert result["event"]["kind"] == "trip.interrupted"
    assert result["event"]["reason"] == "rule_revised"
    assert result["motion_status"] == "unknown"
    assert result["active_trip"] == nil
    assert result["state"].policy.identity == revised.identity

    other_scope = policy(%{id: "other"})

    assert {:error, %{code: :conflict}} =
             MotionTransition.evaluate(
               started["state"],
               started["state"].order_sample,
               other_scope,
               :live,
               2_000
             )
  end

  test "policy and state validation reject mutation and incomplete candidate state" do
    original = policy()

    for change <- [
          %{id: "other"},
          %{revision: "other"},
          %{movement_policy: movement_policy(%{moving_distance_m: 2})},
          %{minimum_movement_ms: 2_000},
          %{minimum_stop_ms: 2_000}
        ] do
      changed = policy(change)
      refute changed.identity == original.identity
      assert {:error, %{code: :conflict}} = MotionTransition.validate(struct(original, change))
    end

    for change <- [
          %{id: ""},
          %{revision: ""},
          %{movement_policy: :invalid},
          %{minimum_movement_ms: 0},
          %{minimum_stop_ms: 604_800_001},
          %{extra: true}
        ] do
      assert {:error, _} = MotionTransition.new(Map.merge(policy_input(), change))
    end

    state = started_trip(original)["state"]

    assert {:error, %{code: :conflict}} =
             MotionTransition.validate_state(%{state | identity: "forged"})

    assert {:error, _} =
             MotionTransition.validate_state(%{
               state
               | candidate_status: "stationary",
                 candidate_since: nil,
                 candidate_sample: nil
             })

    assert {:error, _} = MotionTransition.validate_state(:invalid)
    assert {:error, _} = MotionTransition.new(nil)
    assert {:error, _} = MotionTransition.validate(:invalid)
  end

  property "live and replay produce identical motion state and event identities" do
    check all(offset <- float(min: 0.0001, max: 0.01)) do
      policy = policy()
      first = sample("first-#{offset}", 0, 0, 0)
      second = sample("second-#{offset}", 0, offset, 1_000)
      third = sample("third-#{offset}", 0, offset * 2, 2_000)

      {:ok, baseline} = MotionTransition.evaluate(nil, first, policy, :live, 0)

      {:ok, candidate} =
        MotionTransition.evaluate(baseline["state"], second, policy, :live, 1_000)

      {:ok, live} =
        MotionTransition.evaluate(candidate["state"], third, policy, :live, 2_000)

      {:ok, replay} =
        MotionTransition.evaluate(candidate["state"], third, policy, :replay, 2_000)

      assert live["state"] === replay["state"]
      assert live["event"] === replay["event"]
      assert replay["physical_action_dispatch"] == "prohibited"
    end
  end

  defp started_trip(policy, step \\ 0.0001) do
    first = sample("trip-first-#{step}", 0, 0, 0)
    second = sample("trip-second-#{step}", 0, step, 1_000)
    third = sample("trip-third-#{step}", 0, step * 2, 2_000)
    {:ok, baseline} = MotionTransition.evaluate(nil, first, policy, :live, 0)

    {:ok, candidate} =
      MotionTransition.evaluate(baseline["state"], second, policy, :live, 1_000)

    {:ok, started} =
      MotionTransition.evaluate(candidate["state"], third, policy, :live, 2_000)

    started
  end

  defp policy(changes \\ %{}) do
    {:ok, value} = MotionTransition.new(Map.merge(policy_input(), changes))
    value
  end

  defp policy_input,
    do: %{
      id: "motion-rule",
      revision: "motion-rule-v1",
      movement_policy: movement_policy(),
      minimum_movement_ms: 1_000,
      minimum_stop_ms: 1_000
    }

  defp movement_policy(changes \\ %{}) do
    {:ok, value} =
      PositionMovement.new(
        Map.merge(
          %{
            id: "movement-rule",
            revision: "movement-v1",
            order_policy: order_policy(),
            moving_speed_m_s: 1.0,
            stationary_speed_m_s: 0.1,
            moving_distance_m: 1.0,
            stationary_distance_m: 0.5,
            max_plausible_speed_m_s: 10_000.0,
            max_gap_ms: 10_000,
            uncertainty: :coordinate_only
          },
          changes
        )
      )

    value
  end

  defp order_policy do
    {:ok, value} =
      PositionOrder.new(%{
        revision: "motion-order-v1",
        event_time: :trusted_fix,
        future_skew_ms: 0,
        late_window_ms: 10_000,
        sequence: :none
      })

    value
  end

  defp sample(id, latitude, longitude, event_at, options \\ []) do
    received_at = Keyword.get(options, :received_at, event_at)
    observation = Fixtures.observation(%{id: "capture-" <> id, observed_at: received_at})

    {:ok, evidence} =
      Evidence.new(%{
        id: id,
        kind: :position,
        claim: %{
          "schema" => "wtr.position.v1",
          "latitude" => latitude,
          "longitude" => longitude,
          "altitude_m" => nil,
          "speed_m_s" => nil,
          "horizontal_accuracy_m" => nil,
          "accuracy_kind" => "unknown",
          "source" => "gnss",
          "fix_at" => event_at,
          "device_at" => nil,
          "received_at" => received_at,
          "fix_clock" => "trusted",
          "device_clock" => "unknown",
          "availability" => "available",
          "quality" => "valid",
          "source_units" => %{
            "latitude" => "degree",
            "longitude" => "degree",
            "altitude" => nil,
            "speed" => nil,
            "accuracy" => nil,
            "fix_time" => "unix-ms",
            "device_time" => nil,
            "receiver_time" => "unix-ms"
          },
          "conversion_revision" => "fixture-v1",
          "receiver_observation_id" => observation.id,
          "raw" => %{}
        },
        source_observation_ids: [observation.id],
        evidence_ids: [],
        profile: {"position", "1"},
        decoder: {"position", "1"},
        confidence: :exact,
        reasons: ["fixture"],
        association_id: nil
      })

    {:ok, bundle} = EvidenceBundle.new([observation], [evidence])
    {:ok, position} = Position.new(id, bundle)
    {:ok, sample} = PositionSample.new(position, bundle)
    sample
  end
end
