defmodule Wotex.Tracker.Service.GeofenceRuleStoreTest do
  @moduledoc false
  use ExUnit.Case, async: true
  import Wotex.Tracker.Service.Fixtures

  alias Wotex.Tracker.{
    Evidence,
    EvidenceBundle,
    Geofence,
    GeofenceTransition,
    Position,
    PositionOrder,
    PositionSample
  }

  alias Wotex.Tracker.Service.{RuleTransition, Store}

  test "geofence baseline and entry intent commit atomically across restart" do
    {store, directory} = store()
    fence = fence()
    policy = policy()
    outside = sample("outside", 0.002, now())

    {:ok, baseline_result} =
      GeofenceTransition.evaluate(nil, fence, outside, policy, :live, now())

    {:ok, baseline} = RuleTransition.new("workshop", nil, baseline_result)
    assert {:ok, %{"generation" => "1"}} = Store.commit_rule(store, baseline)

    GenServer.stop(store.pid)
    {reopened, _} = store(directory: directory)

    assert {:ok, durable} =
             Store.rule_state(reopened, "workshop", "geofence", policy.id)

    assert {:ok, restored} = GeofenceTransition.state_from_map(durable["state"])
    assert restored === baseline_result["state"]

    {:ok, entered_result} =
      GeofenceTransition.evaluate(
        restored,
        fence,
        sample("inside", 0, now() + 1_000),
        policy,
        :replay,
        now() + 1_000
      )

    {:ok, entered} = RuleTransition.new("workshop", restored, entered_result)

    assert {:ok, %{"generation" => "2", "event_disposition" => "recorded"} = receipt} =
             Store.commit_rule(reopened, entered)

    assert {:ok, %{"generation" => "2", "disposition" => "duplicate"}} =
             Store.commit_rule(reopened, entered)

    assert {:ok, intent} = Store.rule_event(reopened, "workshop", receipt["event_id"])
    assert intent["kind"] == "geofence"
    assert intent["event"]["kind"] == "geofence.entered"
    assert intent["physical_action_dispatch"] == "prohibited"

    assert {:ok, %{"items" => [%{"id" => "geofence:yard-membership"}]}} =
             Store.snapshot(reopened, query(%{kind: "rules"}))
  end

  test "geofence transition admission rejects stable and altered results" do
    fence = fence()
    policy = policy()
    outside = sample("outside", 0.002, now())

    {:ok, baseline_result} =
      GeofenceTransition.evaluate(nil, fence, outside, policy, :live, now())

    {:ok, baseline} = RuleTransition.new("workshop", nil, baseline_result)
    assert {:ok, ^baseline} = RuleTransition.validate(baseline)

    {:ok, duplicate} =
      GeofenceTransition.evaluate(
        baseline_result["state"],
        fence,
        outside,
        policy,
        :live,
        now()
      )

    refute duplicate["state_changed"]

    assert {:error, :invalid_rule_transition} =
             RuleTransition.new("workshop", baseline_result["state"], duplicate)

    {:ok, entered} =
      GeofenceTransition.evaluate(
        baseline_result["state"],
        fence,
        sample("inside", 0, now() + 1_000),
        policy,
        :live,
        now() + 1_000
      )

    assert {:error, :invalid_rule_transition} =
             RuleTransition.new(
               "workshop",
               baseline_result["state"],
               Map.put(entered, "reason", "changed")
             )
  end

  defp fence do
    {:ok, fence} =
      Geofence.new(%{
        id: "yard",
        revision: "yard-v1",
        shape: %{kind: :circle, latitude: 0, longitude: 0, radius_m: 100},
        boundary: :inside,
        uncertainty: :coordinate_only
      })

    fence
  end

  defp policy do
    {:ok, order_policy} =
      PositionOrder.new(%{
        revision: "geofence-order-v1",
        event_time: :trusted_fix,
        future_skew_ms: 0,
        late_window_ms: 10_000,
        sequence: :none
      })

    {:ok, policy} =
      GeofenceTransition.new(%{
        id: "yard-membership",
        revision: "yard-membership-v1",
        order_policy: order_policy,
        max_transition_gap_ms: 10_000
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
