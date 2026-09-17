defmodule Wotex.Tracker.Service.BatteryRuleStoreTest do
  @moduledoc false
  use ExUnit.Case, async: true
  import Wotex.Tracker.Service.Fixtures

  alias Wotex.Tracker.{
    BatteryTransition,
    Evidence,
    EvidenceBundle,
    Measurement,
    MeasurementSample
  }

  alias Wotex.Tracker.Service.{RuleTransition, Store}

  test "battery state and low intent commit atomically across restart" do
    {store, directory} = store()
    policy = policy()

    {:ok, baseline_result} =
      BatteryTransition.evaluate(nil, sample("normal", 3.0, now()), policy, :live, now())

    {:ok, baseline} = RuleTransition.new("workshop", nil, baseline_result)
    assert {:ok, %{"generation" => "1"}} = Store.commit_rule(store, baseline)

    GenServer.stop(store.pid)
    {reopened, _} = store(directory: directory)
    assert {:ok, durable} = Store.rule_state(reopened, "workshop", "battery", policy.id)
    assert {:ok, restored} = BatteryTransition.state_from_map(durable["state"])
    assert restored === baseline_result["state"]

    {:ok, low_result} =
      BatteryTransition.evaluate(
        restored,
        sample("low", 2.5, now() + 1),
        policy,
        :replay,
        now() + 1
      )

    {:ok, low} = RuleTransition.new("workshop", restored, low_result)

    assert {:ok, %{"generation" => "2", "event_disposition" => "recorded"} = receipt} =
             Store.commit_rule(reopened, low)

    assert {:ok, %{"generation" => "2", "disposition" => "duplicate"}} =
             Store.commit_rule(reopened, low)

    assert {:ok, intent} = Store.rule_event(reopened, "workshop", receipt["event_id"])
    assert intent["kind"] == "battery"
    assert intent["event"] == low_result["event"]
    assert intent["physical_action_dispatch"] == "prohibited"

    assert {:ok, %{"items" => [%{"id" => "battery:battery-rule"}]}} =
             Store.snapshot(reopened, query(%{kind: "rules"}))
  end

  test "battery transition admission rejects stable and changed results" do
    policy = policy()
    normal = sample("normal", 3.0, now())
    {:ok, baseline_result} = BatteryTransition.evaluate(nil, normal, policy, :live, now())
    {:ok, baseline} = RuleTransition.new("workshop", nil, baseline_result)
    assert {:ok, ^baseline} = RuleTransition.validate(baseline)

    {:ok, stable} =
      BatteryTransition.evaluate(baseline_result["state"], normal, policy, :live, now())

    assert stable["state_changed"] == false

    assert {:error, :invalid_rule_transition} =
             RuleTransition.new("workshop", baseline_result["state"], stable)

    {:ok, low} =
      BatteryTransition.evaluate(
        baseline_result["state"],
        sample("low", 2.0, now() + 1),
        policy,
        :live,
        now() + 1
      )

    assert {:error, :invalid_rule_transition} =
             RuleTransition.new(
               "workshop",
               baseline_result["state"],
               put_in(low, ["event", "to_evidence_id"], "changed")
             )
  end

  defp sample(id, value, observed_at) do
    capture = observation(%{id: "capture-#{id}", observed_at: observed_at})

    {:ok, measurement} =
      Measurement.new(%{
        kind: "batteryVoltage",
        value: value,
        unit: "V",
        availability: :available,
        quality: :valid,
        raw: value,
        reason: "fixture"
      })

    {:ok, claim} = Measurement.to_map(measurement)

    {:ok, evidence} =
      Evidence.new(%{
        id: "battery-#{id}",
        kind: :measurement,
        claim: claim,
        source_observation_ids: [capture.id],
        evidence_ids: [],
        profile: {"battery", "1"},
        decoder: {"battery", "1"},
        confidence: :exact,
        reasons: ["fixture"],
        association_id: nil
      })

    {:ok, bundle} = EvidenceBundle.new([capture], [evidence])
    {:ok, sample} = MeasurementSample.new(evidence.id, bundle)
    sample
  end

  defp policy do
    {:ok, value} =
      BatteryTransition.new(%{
        id: "battery-rule",
        revision: "battery-v1",
        measurement_kind: "batteryVoltage",
        unit: "V",
        low_threshold: 2.5,
        clear_threshold: 2.8,
        maximum_age_ms: 1_000,
        future_skew_ms: 0,
        accept_suspect: false
      })

    value
  end

  defp now, do: 1_700_000_000_000
end
