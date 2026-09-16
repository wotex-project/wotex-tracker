defmodule Wotex.Tracker.Service.HeartbeatRuleStoreTest do
  @moduledoc false
  use ExUnit.Case, async: true
  import Wotex.Tracker.Service.Fixtures

  alias Wotex.Tracker.HeartbeatTransition
  alias Wotex.Tracker.Service.{RuleTransition, Store}

  test "heartbeat state and overdue intent commit atomically across restart" do
    {store, directory} = store()
    policy = policy()
    heartbeat = observation(%{id: "heartbeat", observed_at: now()})

    {:ok, baseline_result} =
      HeartbeatTransition.evaluate(nil, heartbeat, policy, :live, now())

    {:ok, baseline} = RuleTransition.new("workshop", nil, baseline_result)

    assert {:ok, %{"generation" => "1", "event_disposition" => "none"}} =
             Store.commit_rule(store, baseline)

    GenServer.stop(store.pid)
    {reopened, _} = store(directory: directory)

    assert {:ok, durable} =
             Store.rule_state(reopened, "workshop", "heartbeat", policy.id)

    assert durable["generation"] == "1"
    assert {:ok, restored} = HeartbeatTransition.state_from_map(durable["state"])
    assert restored === baseline_result["state"]

    {:ok, overdue_result} =
      HeartbeatTransition.evaluate(restored, nil, policy, :replay, restored.due_at)

    {:ok, overdue} = RuleTransition.new("workshop", restored, overdue_result)

    assert {:ok, %{"generation" => "2", "event_disposition" => "recorded"} = receipt} =
             Store.commit_rule(reopened, overdue)

    assert {:ok, %{"generation" => "2", "disposition" => "duplicate"}} =
             Store.commit_rule(reopened, overdue)

    assert {:ok, intent} = Store.rule_event(reopened, "workshop", receipt["event_id"])
    assert intent["kind"] == "heartbeat"
    assert intent["event"] == overdue_result["event"]
    assert intent["mode"] == "replay"
    assert intent["physical_action_dispatch"] == "prohibited"

    assert {:ok, %{"items" => [%{"id" => "heartbeat:heartbeat-rule"}]}} =
             Store.snapshot(reopened, query())
  end

  test "heartbeat transition admission rejects stable and changed results" do
    policy = policy()
    heartbeat = observation(%{id: "heartbeat", observed_at: now()})
    {:ok, baseline_result} = HeartbeatTransition.evaluate(nil, heartbeat, policy, :live, now())
    {:ok, baseline} = RuleTransition.new("workshop", nil, baseline_result)
    assert {:ok, ^baseline} = RuleTransition.validate(baseline)

    assert {:error, :invalid_rule_transition} =
             RuleTransition.validate(%{baseline | kind: "transport_degradation"})

    {:ok, stable} =
      HeartbeatTransition.evaluate(baseline_result["state"], heartbeat, policy, :live, now())

    assert stable["state_changed"] == false

    assert {:error, :invalid_rule_transition} =
             RuleTransition.new("workshop", baseline_result["state"], stable)

    {:ok, overdue} =
      HeartbeatTransition.evaluate(
        baseline_result["state"],
        nil,
        policy,
        :live,
        baseline_result["state"].due_at
      )

    assert {:error, :invalid_rule_transition} =
             RuleTransition.new(
               "workshop",
               baseline_result["state"],
               put_in(overdue, ["event", "to_observation_id"], "changed")
             )
  end

  defp policy do
    {:ok, value} =
      HeartbeatTransition.new(%{
        id: "heartbeat-rule",
        revision: "heartbeat-v1",
        maximum_silence_ms: 10,
        future_skew_ms: 0
      })

    value
  end

  defp now, do: 1_700_000_000_000
end
