defmodule Wotex.Tracker.Service.SuspiciousMovementRuleEventTest do
  @moduledoc false
  use ExUnit.Case, async: true
  import Wotex.Tracker.Service.Fixtures

  alias Wotex.Tracker.{
    Evidence,
    EvidenceBundle,
    MotionTransition,
    PolicyFact,
    Position,
    PositionMovement,
    PositionOrder,
    PositionSample,
    SuspiciousMovement
  }

  alias Wotex.Tracker.Service.{RuleEvent, Store}

  test "suspicious movement intent commits once and survives restart" do
    {store, directory} = store()
    {motion, armed, owner, policy} = inputs()

    {:ok, result} =
      SuspiciousMovement.evaluate(motion, armed, owner, policy, :live, now())

    {:ok, intent} =
      RuleEvent.suspicious_movement("workshop", motion, armed, owner, policy, result)

    assert {:ok, ^intent} = RuleEvent.validate(intent)

    assert {:ok, %{"generation" => "1", "event_disposition" => "recorded"} = receipt} =
             Store.commit_rule_event(store, intent)

    assert {:ok, %{"generation" => "1", "disposition" => "duplicate"}} =
             Store.commit_rule_event(store, intent)

    assert {:ok, event} = Store.rule_event(store, "workshop", receipt["event_id"])
    assert event["kind"] == "suspicious_movement"
    assert event["event"]["kind"] == "suspicious_movement"
    assert event["physical_action_dispatch"] == "separate_authorization_required"

    GenServer.stop(store.pid)
    {reopened, _} = store(directory: directory)

    assert {:ok, %{"generation" => "1", "disposition" => "duplicate"}} =
             Store.commit_rule_event(reopened, intent)
  end

  test "replay metadata is durable and a live collision cannot change its effect" do
    {store, _} = store()
    {motion, armed, owner, policy} = inputs()

    {:ok, replay_result} =
      SuspiciousMovement.evaluate(motion, armed, owner, policy, :replay, now())

    {:ok, replay_intent} =
      RuleEvent.suspicious_movement(
        "workshop",
        motion,
        armed,
        owner,
        policy,
        replay_result
      )

    assert {:ok, %{"event_disposition" => "recorded"} = receipt} =
             Store.commit_rule_event(store, replay_intent)

    assert {:ok, durable} = Store.rule_event(store, "workshop", receipt["event_id"])
    assert durable["mode"] == "replay"
    assert durable["physical_action_dispatch"] == "prohibited"

    {:ok, live_result} =
      SuspiciousMovement.evaluate(motion, armed, owner, policy, :live, now())

    {:ok, live_intent} =
      RuleEvent.suspicious_movement("workshop", motion, armed, owner, policy, live_result)

    assert {:error, :rule_event_conflict} = Store.commit_rule_event(store, live_intent)
  end

  test "event admission rejects changed results and rolls back an injected failure" do
    {motion, armed, owner, policy} = inputs()

    {:ok, result} =
      SuspiciousMovement.evaluate(motion, armed, owner, policy, :live, now())

    assert {:error, :invalid_rule_event} =
             RuleEvent.suspicious_movement(
               "workshop",
               motion,
               armed,
               owner,
               policy,
               Map.put(result, "reason", "changed")
             )

    {:ok, intent} =
      RuleEvent.suspicious_movement("workshop", motion, armed, owner, policy, result)

    assert {:error, :invalid_rule_event} = RuleEvent.validate(%{intent | action: "none"})

    {store, _} =
      store(fault: fn phase -> if phase == :rule_before_commit, do: :abort, else: :ok end)

    assert {:error, :injected_failure} = Store.commit_rule_event(store, intent)
    assert {:error, :not_found} = Store.rule_event(store, "workshop", result["event"]["id"])
  end

  defp inputs do
    motion_policy = motion_policy()
    first = sample("first", 0, now() - 2_000)
    second = sample("second", 0.0001, now() - 1_000)
    third = sample("third", 0.0002, now())

    {:ok, baseline} = MotionTransition.evaluate(nil, first, motion_policy, :replay, now())

    {:ok, candidate} =
      MotionTransition.evaluate(baseline["state"], second, motion_policy, :replay, now())

    {:ok, moving} =
      MotionTransition.evaluate(candidate["state"], third, motion_policy, :replay, now())

    {:ok, policy} =
      SuspiciousMovement.new(%{
        id: "suspicious-rule",
        revision: "suspicious-v1",
        motion_policy: motion_policy,
        armed_predicate: "asset.armed",
        owner_presence_predicate: "owner.present",
        maximum_fact_age_ms: 1_000,
        future_skew_ms: 0,
        owner_unknown_as_absent: false
      })

    {moving["state"], fact("armed", "asset.armed", "true", :identity),
     fact("owner", "owner.present", "false", :transport), policy}
  end

  defp motion_policy do
    {:ok, order} =
      PositionOrder.new(%{
        revision: "order-v1",
        event_time: :trusted_fix,
        future_skew_ms: 0,
        late_window_ms: 10_000,
        sequence: :none
      })

    {:ok, movement} =
      PositionMovement.new(%{
        id: "movement",
        revision: "movement-v1",
        order_policy: order,
        moving_speed_m_s: 1,
        stationary_speed_m_s: 0.1,
        moving_distance_m: 1,
        stationary_distance_m: 0.5,
        max_plausible_speed_m_s: 1_000,
        max_gap_ms: 10_000,
        uncertainty: :coordinate_only
      })

    {:ok, policy} =
      MotionTransition.new(%{
        id: "motion",
        revision: "motion-v1",
        movement_policy: movement,
        minimum_movement_ms: 1_000,
        minimum_stop_ms: 1_000
      })

    policy
  end

  defp fact(id, predicate, status, kind) do
    capture = observation(%{id: "fact-capture-#{id}", observed_at: now()})

    {:ok, evidence} =
      Evidence.new(%{
        id: id,
        kind: kind,
        claim: %{
          "schema" => "wtr.policy-fact.v1",
          "predicate" => predicate,
          "status" => status,
          "policy_revision" => "facts-v1",
          "reason" => "fixture"
        },
        source_observation_ids: [capture.id],
        evidence_ids: [],
        profile: {"policy", "1"},
        decoder: {"policy", "1"},
        confidence: :exact,
        reasons: ["fixture"],
        association_id: nil
      })

    {:ok, bundle} = EvidenceBundle.new([capture], [evidence])
    {:ok, value} = PolicyFact.new(id, bundle)
    value
  end

  defp sample(id, longitude, event_at) do
    capture = observation(%{id: "capture-#{id}", observed_at: event_at})

    {:ok, evidence} =
      Evidence.new(%{
        id: "position-#{id}",
        kind: :position,
        claim: %{
          "schema" => "wtr.position.v1",
          "latitude" => 0,
          "longitude" => longitude,
          "altitude_m" => nil,
          "speed_m_s" => nil,
          "horizontal_accuracy_m" => nil,
          "accuracy_kind" => "unknown",
          "source" => "gnss",
          "fix_at" => event_at,
          "device_at" => nil,
          "received_at" => event_at,
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
          "receiver_observation_id" => capture.id,
          "raw" => %{}
        },
        source_observation_ids: [capture.id],
        evidence_ids: [],
        profile: {"position", "1"},
        decoder: {"position", "1"},
        confidence: :exact,
        reasons: ["fixture"],
        association_id: nil
      })

    {:ok, bundle} = EvidenceBundle.new([capture], [evidence])
    {:ok, position} = Position.new(evidence.id, bundle)
    {:ok, value} = PositionSample.new(position, bundle)
    value
  end

  defp now, do: 1_700_000_000_000
end
