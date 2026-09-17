defmodule Wotex.Tracker.Service.GeofenceCrossingRuleEventTest do
  @moduledoc false
  use ExUnit.Case, async: true
  import Wotex.Tracker.Service.Fixtures

  alias Wotex.Tracker.{
    Evidence,
    EvidenceBundle,
    Geofence,
    GeofenceCrossing,
    Position,
    PositionOrder,
    PositionSample
  }

  alias Wotex.Tracker.Service.{RuleEvent, RuleEventProjection, Store}

  test "inferred crossing intent commits once and survives restart" do
    {store, directory} = store()
    {fence, from, to, policy} = inputs()
    {:ok, result} = GeofenceCrossing.evaluate(fence, from, to, policy, :live, now())
    {:ok, intent} = RuleEvent.geofence_crossing("workshop", fence, from, to, policy, result)
    assert {:ok, ^intent} = RuleEvent.validate(intent)

    assert {:ok, %{"generation" => "1", "event_disposition" => "recorded"} = receipt} =
             Store.commit_rule_event(store, intent)

    assert {:ok, %{"generation" => "1", "disposition" => "duplicate"}} =
             Store.commit_rule_event(store, intent)

    assert {:ok, event} = Store.rule_event(store, "workshop", receipt["event_id"])
    assert event["kind"] == "geofence_crossing"
    assert event["event"]["kind"] == "geofence.crossing_inferred"
    assert event["physical_action_dispatch"] == "separate_authorization_required"

    assert {:ok, %{"items" => [%{"event" => envelope}]}} =
             Store.events(store, replay())

    assert envelope == %{
             "type" => "tracker.event",
             "data" => RuleEventProjection.public(result["event"])
           }

    GenServer.stop(store.pid)
    {reopened, _} = store(directory: directory)

    assert {:ok, %{"generation" => "1", "disposition" => "duplicate"}} =
             Store.commit_rule_event(reopened, intent)
  end

  test "replay metadata is durable and a live collision cannot change its effect" do
    {store, _} = store()
    {fence, from, to, policy} = inputs()

    {:ok, replay_result} =
      GeofenceCrossing.evaluate(fence, from, to, policy, :replay, now())

    {:ok, replay_intent} =
      RuleEvent.geofence_crossing("workshop", fence, from, to, policy, replay_result)

    assert {:ok, %{"event_disposition" => "recorded"} = receipt} =
             Store.commit_rule_event(store, replay_intent)

    assert {:ok, durable} = Store.rule_event(store, "workshop", receipt["event_id"])
    assert durable["mode"] == "replay"
    assert durable["physical_action_dispatch"] == "prohibited"

    {:ok, live_result} = GeofenceCrossing.evaluate(fence, from, to, policy, :live, now())

    {:ok, live_intent} =
      RuleEvent.geofence_crossing("workshop", fence, from, to, policy, live_result)

    assert {:error, :rule_event_conflict} = Store.commit_rule_event(store, live_intent)
  end

  test "event admission rejects changed results and pre-commit failure leaves no intent" do
    {fence, from, to, policy} = inputs()
    {:ok, result} = GeofenceCrossing.evaluate(fence, from, to, policy, :live, now())

    assert {:error, :invalid_rule_event} =
             RuleEvent.geofence_crossing(
               "workshop",
               fence,
               from,
               to,
               policy,
               Map.put(result, "reason", "changed")
             )

    {:ok, intent} = RuleEvent.geofence_crossing("workshop", fence, from, to, policy, result)
    assert {:error, :invalid_rule_event} = RuleEvent.validate(%{intent | action: "none"})

    {store, _} =
      store(fault: fn phase -> if phase == :rule_before_commit, do: :abort, else: :ok end)

    assert {:error, :injected_failure} = Store.commit_rule_event(store, intent)
    assert {:error, :not_found} = Store.rule_event(store, "workshop", result["event"]["id"])
    assert {:error, :invalid_rule_event} = Store.commit_rule_event(store, :invalid)
  end

  defp inputs do
    {:ok, fence} =
      Geofence.new(%{
        id: "yard",
        revision: "yard-v1",
        shape: %{kind: :circle, latitude: 0, longitude: 0, radius_m: 100},
        boundary: :outside,
        uncertainty: :coordinate_only
      })

    {:ok, order_policy} =
      PositionOrder.new(%{
        revision: "crossing-order-v1",
        event_time: :trusted_fix,
        future_skew_ms: 0,
        late_window_ms: 10_000,
        sequence: :none
      })

    {:ok, policy} =
      GeofenceCrossing.new(%{
        id: "crossing-rule",
        revision: "crossing-rule-v1",
        order_policy: order_policy,
        max_gap_ms: 10_000,
        max_distance_m: 500
      })

    {fence, sample("from", -0.002, now() - 1), sample("to", 0.002, now()), policy}
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
