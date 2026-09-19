defmodule Wotex.Tracker.Service.NotificationIntentTest do
  @moduledoc false

  use ExUnit.Case, async: true
  import Wotex.Tracker.Service.Fixtures

  alias Wotex.Tracker.HeartbeatTransition

  alias Wotex.Tracker.Service

  alias Wotex.Tracker.Service.{
    Codec,
    ForwardItem,
    Identifier,
    RuleFixtures,
    RuleTransition,
    Store
  }

  test "a live alert atomically stages one minimal durable reference per endpoint" do
    c = service()
    register!(c, "phone", "private-apns-token", "0")

    assert {:ok, %{"items" => []}} =
             Store.claim_forward(c.store, c.scope, c.now, 10, 1_000)

    RuleFixtures.commit_heartbeat_versions(c.store, c.scope, "notify", 2)

    assert {:ok, %{"items" => [%{"id" => alert_id, "generation" => "3"}]}} =
             Service.list(c.service, c.reader, c.scope, "alerts", %{}, c.now + 10)

    assert {:ok, %{"items" => [%{"id" => internal_id}]}} =
             Store.snapshot(c.store, %{
               scope: c.scope,
               kind: "notification_endpoints",
               generation: nil,
               after: "",
               limit: 10
             })

    queue_id = queue_id(c.scope, alert_id, internal_id)
    assert {:ok, %{"status" => "pending"}} = Store.forward_status(c.store, c.scope, queue_id)

    GenServer.stop(c.store.pid)
    {reopened, _directory} = store(directory: c.directory, credentials: c.credentials)

    assert {:ok, %{"items" => [item]}} =
             Store.claim_forward(reopened, c.scope, c.now + 100, 10, 1_000)

    assert item["schema"] == "wtr.forward-item.v1"
    assert item["bearer"] == "push"
    assert item["application_protocol"] == "apns"
    assert item["source"] == "lossy"
    assert item["required_acknowledgement"] == "application"
    assert item["candidate_id"] =~ ~r/^wtr1_[A-Za-z0-9_-]+@notification-endpoint-1$/

    assert item["payload"] == %{
             "schema" => "wtr.notification-reference.v1",
             "event_ref" => alert_id
           }

    encoded = Codec.encode!(item)
    refute encoded =~ "heartbeat.overdue"
    refute encoded =~ "notify"
    refute encoded =~ "private-apns-token"
    refute encoded =~ "location"
  end

  test "replay alerts remain canonical history without staging notifications" do
    c = service()
    register!(c, "phone", "private-apns-token", "0")
    {baseline, overdue} = heartbeat_transitions(c.scope, :replay)

    assert {:ok, %{"generation" => "2"}} = Store.commit_rule(c.store, baseline)

    assert {:ok, %{"generation" => "3", "event_disposition" => "recorded"}} =
             Store.commit_rule(c.store, overdue)

    assert {:ok, %{"items" => [%{"value" => %{"mode" => "replay"}}]}} =
             Service.list(c.service, c.reader, c.scope, "alerts", %{}, c.now + 10)

    assert {:ok, %{"items" => []}} =
             Store.claim_forward(c.store, c.scope, c.now + 10, 10, 1_000)
  end

  test "a failed rule commit rolls its staged notification back with the alert" do
    c = service()
    register!(c, "phone", "private-apns-token", "0")
    {baseline, overdue} = heartbeat_transitions(c.scope, :live)
    assert {:ok, %{"generation" => "2"}} = Store.commit_rule(c.store, baseline)
    GenServer.stop(c.store.pid)

    {failed, _directory} =
      store(
        directory: c.directory,
        credentials: c.credentials,
        fault: fn phase -> if phase == :rule_before_commit, do: :abort, else: :ok end
      )

    assert {:error, :injected_failure} = Store.commit_rule(failed, overdue)
    assert {:error, :not_found} = Store.rule_event(failed, c.scope, overdue.event["id"])

    assert {:ok, %{"items" => []}} =
             Store.snapshot(failed, %{
               scope: c.scope,
               kind: "alerts",
               generation: nil,
               after: "",
               limit: 10
             })

    assert {:ok, %{"items" => []}} =
             Store.claim_forward(failed, c.scope, c.now + 10, 10, 1_000)
  end

  test "queue pressure records a dropped notification without rolling back its alert" do
    c = service(forward_max_items: 1)
    register!(c, "phone", "private-apns-token", "0")

    {:ok, pending} =
      ForwardItem.new(%{
        scope: c.scope,
        id: "already-pending",
        candidate_id: "other",
        bearer: "network",
        application_protocol: "fixture",
        payload: %{},
        source: :reliable,
        admitted_at: c.now,
        required_acknowledgement: :none
      })

    assert {:ok, %{"status" => "pending"}} = Store.enqueue_forward(c.store, pending)
    RuleFixtures.commit_heartbeat_versions(c.store, c.scope, "overflow", 2)

    assert {:ok, %{"items" => [%{"id" => alert_id}]}} =
             Service.list(c.service, c.reader, c.scope, "alerts", %{}, c.now + 10)

    assert {:ok, %{"items" => [%{"id" => internal_id}]}} =
             Store.snapshot(c.store, %{
               scope: c.scope,
               kind: "notification_endpoints",
               generation: nil,
               after: "",
               limit: 10
             })

    queue_id = queue_id(c.scope, alert_id, internal_id)

    assert {:ok, %{"status" => "discarded", "reason" => "overflow"}} =
             Store.forward_status(c.store, c.scope, queue_id)
  end

  defp register!(c, id, token, generation) do
    assert {:ok, _receipt} =
             Service.register_notification_endpoint(
               c.service,
               c.admin,
               c.scope,
               Identifier.uuid(),
               %{
                 "id" => id,
                 "provider" => "apns",
                 "app_id" => "org.wotex.tracker",
                 "environment" => "sandbox",
                 "token" => token,
                 "expected_generation" => generation
               },
               c.now
             )
  end

  defp heartbeat_transitions(scope, mode) do
    policy = RuleFixtures.heartbeat_policy("notification-heartbeat")
    capture = observation(%{id: "notification-capture", observed_at: RuleFixtures.now()})

    {:ok, baseline_result} =
      HeartbeatTransition.evaluate(nil, capture, policy, mode, RuleFixtures.now())

    {:ok, overdue_result} =
      HeartbeatTransition.evaluate(
        baseline_result["state"],
        nil,
        policy,
        mode,
        baseline_result["state"].due_at
      )

    {:ok, baseline} = RuleTransition.new(scope, nil, baseline_result)
    {:ok, overdue} = RuleTransition.new(scope, baseline_result["state"], overdue_result)
    {baseline, overdue}
  end

  defp queue_id(scope, alert_id, internal_id),
    do:
      "notification:" <>
        Codec.digest(%{
          "scope" => scope,
          "alert" => alert_id,
          "candidate" => internal_id <> "@notification-endpoint-1"
        })
end
