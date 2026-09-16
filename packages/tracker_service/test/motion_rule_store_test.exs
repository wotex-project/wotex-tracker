defmodule Wotex.Tracker.Service.MotionRuleStoreTest do
  @moduledoc false
  use ExUnit.Case, async: true
  import Wotex.Tracker.Service.Fixtures

  alias Wotex.Tracker.{
    Evidence,
    EvidenceBundle,
    MotionTransition,
    Position,
    PositionMovement,
    PositionOrder,
    PositionSample
  }

  alias Wotex.Tracker.Service.{RuleTransition, Store}

  test "pending motion state and trip-start intent commit atomically across restart" do
    {store, directory} = store()
    policy = policy()

    {:ok, baseline_result} =
      MotionTransition.evaluate(nil, sample("first", 0, now()), policy, :live, now())

    {:ok, baseline} = RuleTransition.new("workshop", nil, baseline_result)
    assert {:ok, %{"generation" => "1"}} = Store.commit_rule(store, baseline)

    {:ok, candidate_result} =
      MotionTransition.evaluate(
        baseline_result["state"],
        sample("second", 0.0001, now() + 1_000),
        policy,
        :live,
        now() + 1_000
      )

    {:ok, candidate} =
      RuleTransition.new("workshop", baseline_result["state"], candidate_result)

    assert {:ok, %{"generation" => "2", "event_disposition" => "none"}} =
             Store.commit_rule(store, candidate)

    GenServer.stop(store.pid)
    {reopened, _} = store(directory: directory)
    assert {:ok, durable} = Store.rule_state(reopened, "workshop", "motion", policy.id)
    assert {:ok, restored} = MotionTransition.state_from_map(durable["state"])
    assert restored === candidate_result["state"]

    {:ok, started_result} =
      MotionTransition.evaluate(
        restored,
        sample("third", 0.0002, now() + 2_000),
        policy,
        :replay,
        now() + 2_000
      )

    {:ok, started} = RuleTransition.new("workshop", restored, started_result)

    assert {:ok, %{"generation" => "3", "event_disposition" => "recorded"} = receipt} =
             Store.commit_rule(reopened, started)

    assert {:ok, %{"generation" => "3", "disposition" => "duplicate"}} =
             Store.commit_rule(reopened, started)

    assert {:ok, intent} = Store.rule_event(reopened, "workshop", receipt["event_id"])
    assert intent["kind"] == "motion"
    assert intent["event"]["kind"] == "trip.started"
    assert intent["physical_action_dispatch"] == "prohibited"

    assert {:ok, %{"items" => [%{"id" => "motion:motion-rule"}]}} =
             Store.snapshot(reopened, query())
  end

  test "motion transition admission rejects stable and changed results" do
    policy = policy()
    first = sample("first", 0, now())
    {:ok, baseline_result} = MotionTransition.evaluate(nil, first, policy, :live, now())
    {:ok, baseline} = RuleTransition.new("workshop", nil, baseline_result)
    assert {:ok, ^baseline} = RuleTransition.validate(baseline)

    {:ok, stable} =
      MotionTransition.evaluate(baseline_result["state"], first, policy, :live, now())

    assert stable["state_changed"] == false

    assert {:error, :invalid_rule_transition} =
             RuleTransition.new("workshop", baseline_result["state"], stable)

    {:ok, candidate} =
      MotionTransition.evaluate(
        baseline_result["state"],
        sample("second", 0.0001, now() + 1_000),
        policy,
        :live,
        now() + 1_000
      )

    assert {:error, :invalid_rule_transition} =
             RuleTransition.new(
               "workshop",
               baseline_result["state"],
               Map.put(candidate, "reason", "changed")
             )
  end

  defp policy do
    {:ok, order_policy} =
      PositionOrder.new(%{
        revision: "motion-order-v1",
        event_time: :trusted_fix,
        future_skew_ms: 0,
        late_window_ms: 10_000,
        sequence: :none
      })

    {:ok, movement_policy} =
      PositionMovement.new(%{
        id: "movement-rule",
        revision: "movement-v1",
        order_policy: order_policy,
        moving_speed_m_s: 1.0,
        stationary_speed_m_s: 0.1,
        moving_distance_m: 1.0,
        stationary_distance_m: 0.5,
        max_plausible_speed_m_s: 10_000.0,
        max_gap_ms: 10_000,
        uncertainty: :coordinate_only
      })

    {:ok, policy} =
      MotionTransition.new(%{
        id: "motion-rule",
        revision: "motion-rule-v1",
        movement_policy: movement_policy,
        minimum_movement_ms: 1_000,
        minimum_stop_ms: 1_000
      })

    policy
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
    {:ok, sample} = PositionSample.new(position, bundle)
    sample
  end

  defp now, do: 1_700_000_000_000
end
