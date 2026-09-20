defmodule Wotex.Tracker.Service.NotificationDispatcherTest do
  @moduledoc false

  use ExUnit.Case, async: true
  import Wotex.Tracker.Service.Fixtures

  alias Wotex.Tracker.Service

  alias Wotex.Tracker.Service.{
    Codec,
    ForwardItem,
    Identifier,
    NotificationAdapter,
    NotificationDispatcher,
    NotificationTarget,
    RuleFixtures,
    Store
  }

  defmodule Adapter do
    @behaviour NotificationAdapter

    @impl true
    def deliver({owner, result}, target, payload) do
      send(owner, {:delivery, target, payload})

      case result do
        :raise -> raise "private adapter failure"
        {:throw, reason} -> throw(reason)
        fun when is_function(fun, 2) -> fun.(target, payload)
        result -> result
      end
    end
  end

  defmodule BlockingAdapter do
    @behaviour NotificationAdapter

    @impl true
    def deliver(owner, _target, _payload) do
      send(owner, {:blocking_delivery, self()})
      receive do: (:release -> {:retry, :unavailable})
    end
  end

  test "provider acceptance completes only the minimal claimed reference" do
    c = staged()

    dispatcher =
      start_dispatcher(c, {:accepted, "apns-request-1"},
        scopes: [c.scope, "z-secondary"],
        max_batch: 1
      )

    assert_receive {:delivery, target, payload}, 1_000
    assert %NotificationTarget{} = target
    assert target.token == "private-apns-token"
    refute inspect(target) =~ "private-apns-token"
    assert payload == %{"schema" => "wtr.notification-reference.v1", "event_ref" => c.alert_id}

    eventually(fn ->
      match?(
        {:ok,
         %{
           "status" => "delivered",
           "completion" => %{
             "status" => "acknowledged",
             "layer" => "application",
             "reference" => "apns-request-1"
           }
         }},
        Store.forward_status(c.store, c.scope, c.queue_id)
      ) and
        match?(
          {:ok,
           %{
             "running" => false,
             "last_result" => %{"accepted" => 1, "claimed" => 1}
           }},
          NotificationDispatcher.snapshot(dispatcher)
        )
    end)

    assert {:ok,
            %{
              "schema" => "wtr.notification-dispatcher.v1",
              "running" => false,
              "last_result" => %{"accepted" => 1, "claimed" => 1}
            }} = NotificationDispatcher.snapshot(dispatcher)

    assert :ok = NotificationDispatcher.dispatch(dispatcher)

    eventually(fn ->
      match?(
        {:ok, %{"running" => false, "last_result" => %{"claimed" => 0}}},
        NotificationDispatcher.snapshot(dispatcher)
      )
    end)
  end

  test "retryable outcomes remain pending for a later durable attempt" do
    c = staged()
    dispatcher = start_dispatcher(c, {:retry, :rate_limited})

    assert_receive {:delivery, %NotificationTarget{}, _payload}, 1_000

    eventually(fn ->
      match?(
        {:ok, %{"status" => "pending", "attempts" => 1}},
        Store.forward_status(c.store, c.scope, c.queue_id)
      ) and
        match?(
          {:ok, %{"running" => false, "last_result" => %{"retrying" => 1}}},
          NotificationDispatcher.snapshot(dispatcher)
        )
    end)
  end

  test "an invalid provider token removes only the still-matching endpoint" do
    c = staged()
    _dispatcher = start_dispatcher(c, {:invalid_token, "apns-request-invalid"})

    assert_receive {:delivery, %NotificationTarget{id: "phone"}, _payload}, 1_000

    eventually(fn ->
      match?(
        {:ok, %{"status" => "discarded", "reason" => "invalid_token"}},
        Store.forward_status(c.store, c.scope, c.queue_id)
      )
    end)

    assert {:error, %{"code" => "not_found"}} =
             Service.notification_endpoint(c.service, c.admin, c.scope, "phone", c.now + 101)
  end

  test "rotation and revocation prevent delivery without removing current endpoint state" do
    rotated = staged()
    register!(rotated, "new-private-token", "3")
    _dispatcher = start_dispatcher(rotated, {:accepted, "must-not-send"})

    refute_receive {:delivery, _, _}, 50

    eventually(fn ->
      match?(
        {:ok, %{"status" => "discarded", "reason" => "endpoint_rotated"}},
        Store.forward_status(rotated.store, rotated.scope, rotated.queue_id)
      )
    end)

    assert {:ok, %{"value" => %{"revision" => "notification-endpoint-4"}}} =
             Service.notification_endpoint(
               rotated.service,
               rotated.admin,
               rotated.scope,
               "phone",
               rotated.now + 101
             )

    revoked = staged()

    assert {:ok, %{"generation" => "4"}} =
             Service.revoke(
               revoked.service,
               revoked.admin,
               revoked.scope,
               Identifier.uuid(),
               %{"credential_id" => "admin", "expected_generation" => "3"},
               revoked.now + 10
             )

    _dispatcher = start_dispatcher(revoked, {:accepted, "must-not-send-either"})
    refute_receive {:delivery, _, _}, 50

    eventually(fn ->
      match?(
        {:ok, %{"status" => "discarded", "reason" => "authorization_revoked"}},
        Store.forward_status(revoked.store, revoked.scope, revoked.queue_id)
      )
    end)
  end

  test "permanent provider rejection is a distinct terminal outcome" do
    c = staged()
    _dispatcher = start_dispatcher(c, {:rejected, "apns-request-rejected"})
    assert_receive {:delivery, %NotificationTarget{}, _payload}, 1_000

    eventually(fn ->
      match?(
        {:ok, %{"status" => "discarded", "reason" => "provider_rejected"}},
        Store.forward_status(c.store, c.scope, c.queue_id)
      )
    end)
  end

  test "a removed endpoint is terminal without invoking the provider" do
    c = staged()

    assert {:ok, %{"generation" => "4"}} =
             Service.unregister_notification_endpoint(
               c.service,
               c.admin,
               c.scope,
               Identifier.uuid(),
               %{"id" => "phone", "expected_generation" => "3"},
               c.now + 10
             )

    _dispatcher = start_dispatcher(c, {:accepted, "must-not-send"})
    refute_receive {:delivery, _, _}, 50

    eventually(fn ->
      match?(
        {:ok, %{"status" => "discarded", "reason" => "endpoint_missing"}},
        Store.forward_status(c.store, c.scope, c.queue_id)
      )
    end)
  end

  test "malformed and crashing adapter outcomes remain retryable" do
    malformed = staged()
    malformed_dispatcher = start_dispatcher(malformed, {:accepted, ""})
    assert_receive {:delivery, %NotificationTarget{}, _payload}, 1_000

    eventually(fn ->
      match?(
        {:ok, %{"running" => false, "last_result" => %{"retrying" => 1}}},
        NotificationDispatcher.snapshot(malformed_dispatcher)
      )
    end)

    crashing = staged()
    crashing_dispatcher = start_dispatcher(crashing, :raise)
    assert_receive {:delivery, %NotificationTarget{}, _payload}, 1_000

    eventually(fn ->
      match?(
        {:ok, %{"running" => false, "last_result" => %{"retrying" => 1}}},
        NotificationDispatcher.snapshot(crashing_dispatcher)
      )
    end)

    thrown = staged()
    thrown_dispatcher = start_dispatcher(thrown, {:throw, :private_failure})
    assert_receive {:delivery, %NotificationTarget{}, _payload}, 1_000

    eventually(fn ->
      match?(
        {:ok, %{"running" => false, "last_result" => %{"retrying" => 1}}},
        NotificationDispatcher.snapshot(thrown_dispatcher)
      )
    end)
  end

  test "endpoint rotation during an invalid-token response preserves the new registration" do
    c = staged()

    rotate = fn _target, _payload ->
      {:ok, _} =
        Service.register_notification_endpoint(
          c.service,
          c.admin,
          c.scope,
          Identifier.uuid(),
          %{
            "id" => "phone",
            "provider" => "apns",
            "app_id" => "org.wotex.tracker",
            "environment" => "sandbox",
            "token" => "replacement-private-token",
            "expected_generation" => "3"
          },
          c.now + 10
        )

      {:invalid_token, "stale-apns-request"}
    end

    _dispatcher = start_dispatcher(c, rotate)
    assert_receive {:delivery, %NotificationTarget{revision: "notification-endpoint-1"}, _}, 1_000

    eventually(fn ->
      match?(
        {:ok, %{"status" => "discarded", "reason" => "endpoint_rotated"}},
        Store.forward_status(c.store, c.scope, c.queue_id)
      )
    end)

    assert {:ok, %{"value" => %{"revision" => "notification-endpoint-4"}}} =
             Service.notification_endpoint(c.service, c.admin, c.scope, "phone", c.now + 100)
  end

  test "authority revoked during provider delivery leaves invalidation retryable" do
    c = staged()

    revoke = fn _target, _payload ->
      {:ok, _} =
        Service.revoke(
          c.service,
          c.admin,
          c.scope,
          Identifier.uuid(),
          %{"credential_id" => "admin", "expected_generation" => "3"},
          c.now + 10
        )

      {:invalid_token, "concurrent-revocation"}
    end

    dispatcher = start_dispatcher(c, revoke)
    assert_receive {:delivery, %NotificationTarget{}, _payload}, 1_000

    eventually(fn ->
      match?(
        {:ok, %{"running" => false, "last_result" => %{"retrying" => 1}}},
        NotificationDispatcher.snapshot(dispatcher)
      )
    end)

    assert {:ok, %{"status" => "pending", "attempts" => 1}} =
             Store.forward_status(c.store, c.scope, c.queue_id)
  end

  test "a concurrent terminal queue outcome cannot be relabeled as provider acceptance" do
    c = staged()
    assert {:ok, receipt} = Store.forward_status(c.store, c.scope, c.queue_id)

    settle = fn _target, _payload ->
      {:ok, _} =
        Store.discard_forward(
          c.store,
          c.scope,
          c.queue_id,
          receipt["queue_identity"],
          "provider_rejected",
          c.now + 100
        )

      {:accepted, "late-provider-acceptance"}
    end

    dispatcher = start_dispatcher(c, settle)
    assert_receive {:delivery, %NotificationTarget{}, _payload}, 1_000

    eventually(fn ->
      match?(
        {:ok, %{"running" => false, "last_result" => %{"failed" => 1}}},
        NotificationDispatcher.snapshot(dispatcher)
      )
    end)

    assert {:ok, %{"status" => "discarded", "reason" => "provider_rejected"}} =
             Store.forward_status(c.store, c.scope, c.queue_id)
  end

  test "clock failures are contained inside one delivery cycle" do
    for failing_clock <- [
          fn -> raise "private clock failure" end,
          fn -> exit(:clock_failure) end
        ] do
      c = service()
      dispatcher = start_dispatcher(c, {:retry, :unavailable}, clock: failing_clock)

      eventually(fn ->
        match?(
          {:ok, %{"running" => false, "last_result" => %{"failed" => 1}}},
          NotificationDispatcher.snapshot(dispatcher)
        )
      end)
    end
  end

  test "a store claim failure stops the current cycle without losing queued work" do
    c = staged()
    GenServer.stop(c.store.pid)

    {failed_store, _} =
      store(
        directory: c.directory,
        credentials: c.credentials,
        fault: fn phase -> if phase == :forward_before_commit, do: :abort, else: :ok end
      )

    c = %{c | store: failed_store}
    dispatcher = start_dispatcher(c, {:accepted, "must-not-send"})

    eventually(fn ->
      match?(
        {:ok, %{"running" => false, "last_result" => %{"failed" => 1}}},
        NotificationDispatcher.snapshot(dispatcher)
      )
    end)

    refute_receive {:delivery, _, _}, 50

    assert {:ok, %{"status" => "pending", "attempts" => 0}} =
             Store.forward_status(failed_store, c.scope, c.queue_id)
  end

  test "a timed-out adapter worker is killed while the dispatcher remains available" do
    c = staged()

    dispatcher =
      start_dispatcher(c, :unused,
        adapter: {BlockingAdapter, self()},
        timeout_ms: 25
      )

    assert_receive {:blocking_delivery, worker}, 1_000
    assert Process.alive?(worker)
    assert {:error, :busy} = NotificationDispatcher.dispatch(dispatcher)
    send(dispatcher, :dispatch)
    send(dispatcher, :unexpected)

    eventually(fn ->
      match?(
        {:ok, %{"running" => false, "last_result" => %{"failed" => 1}}},
        NotificationDispatcher.snapshot(dispatcher)
      )
    end)

    refute Process.alive?(worker)
    assert Process.alive?(dispatcher)
    GenServer.stop(dispatcher)
    assert {:error, :storage_unavailable} = NotificationDispatcher.snapshot(dispatcher)
  end

  test "an unavailable supervised store records a failed bounded cycle" do
    c = service()
    {:ok, supervisor} = Supervisor.start_link([], strategy: :one_for_one)
    Supervisor.stop(supervisor)

    dispatcher =
      start_dispatcher(c, {:retry, :unavailable}, store: {:supervisor, supervisor})

    eventually(fn ->
      match?(
        {:ok, %{"running" => false, "last_result" => %{"failed" => 1}}},
        NotificationDispatcher.snapshot(dispatcher)
      )
    end)
  end

  test "default scope and clock discovery work through a supervised store" do
    c = service()
    isolated_directory = directory()

    store_child =
      Supervisor.child_spec(
        {Store, directory: isolated_directory, credentials: c.credentials},
        id: :store
      )

    {:ok, supervisor} = Supervisor.start_link([store_child], strategy: :one_for_one)

    on_exit(fn ->
      try do
        Supervisor.stop(supervisor)
      catch
        :exit, _ -> :ok
      end
    end)

    dispatcher =
      start_supervised!(
        Supervisor.child_spec(
          {NotificationDispatcher,
           store: {:supervisor, supervisor},
           credentials: c.credentials,
           adapter: {Adapter, {self(), {:retry, :unavailable}}}},
          id: make_ref(),
          restart: :temporary
        )
      )

    eventually(fn ->
      match?(
        {:ok, %{"running" => false, "last_result" => %{"claimed" => 0, "failed" => 0}}},
        NotificationDispatcher.snapshot(dispatcher)
      )
    end)
  end

  test "a malformed durable endpoint target fails closed without provider delivery" do
    c = service()

    {:ok, malformed} =
      ForwardItem.new(%{
        scope: c.scope,
        id: "malformed-notification",
        candidate_id: "malformed-target",
        bearer: "push",
        application_protocol: "apns",
        payload: %{"schema" => "wtr.notification-reference.v1", "event_ref" => "alert-1"},
        source: :lossy,
        admitted_at: c.now,
        required_acknowledgement: :application
      })

    assert {:ok, _} = Store.enqueue_forward(c.store, malformed)
    dispatcher = start_dispatcher(c, {:accepted, "must-not-send"})

    eventually(fn ->
      match?(
        {:ok, %{"running" => false, "last_result" => %{"retrying" => 1}}},
        NotificationDispatcher.snapshot(dispatcher)
      )
    end)

    refute_receive {:delivery, _, _}, 50

    assert {:ok, %{"status" => "pending", "attempts" => 1}} =
             Store.forward_status(c.store, c.scope, malformed.id)
  end

  test "configuration is explicit, bounded and redacted" do
    c = service()

    for options <- [
          [],
          [store: c.store, credentials: c.credentials, adapter: {String, nil}],
          [store: :invalid, credentials: c.credentials, adapter: {Adapter, {self(), :invalid}}],
          [store: c.store, credentials: c.credentials, adapter: :invalid],
          [
            store: c.store,
            credentials: c.credentials,
            adapter: {Adapter, {self(), {:retry, :timeout}}},
            max_batch: 0
          ],
          [
            store: c.store,
            credentials: c.credentials,
            adapter: {Adapter, {self(), {:retry, :timeout}}},
            unknown: true
          ]
        ] do
      assert {:error, :invalid_options} = NotificationDispatcher.start_link(options)
    end

    dispatcher = start_dispatcher(c, {:retry, :timeout}, scopes: [c.scope])
    status = :sys.get_status(dispatcher) |> inspect()
    refute status =~ c.admin
    refute status =~ "private-apns-token"
  end

  defp staged do
    c = service()
    register!(c, "private-apns-token", "0")
    RuleFixtures.commit_heartbeat_versions(c.store, c.scope, "notify", 2)

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

    queue_id =
      "notification:" <>
        Codec.digest(%{
          "scope" => c.scope,
          "alert" => alert_id,
          "candidate" => internal_id <> "@notification-endpoint-1"
        })

    Map.merge(c, %{alert_id: alert_id, queue_id: queue_id})
  end

  defp register!(c, token, generation) do
    assert {:ok, _} =
             Service.register_notification_endpoint(
               c.service,
               c.admin,
               c.scope,
               Identifier.uuid(),
               %{
                 "id" => "phone",
                 "provider" => "apns",
                 "app_id" => "org.wotex.tracker",
                 "environment" => "sandbox",
                 "token" => token,
                 "expected_generation" => generation
               },
               c.now
             )
  end

  defp start_dispatcher(c, result, options \\ []) do
    start_supervised!(
      Supervisor.child_spec(
        {NotificationDispatcher,
         Keyword.merge(
           [
             store: c.store,
             credentials: c.credentials,
             adapter: {Adapter, {self(), result}},
             scopes: [c.scope],
             clock: fn -> c.now + 100 end,
             interval_ms: 60_000,
             retry_after_ms: 1_000
           ],
           options
         )},
        id: make_ref(),
        restart: :temporary
      )
    )
  end

  defp eventually(check, attempts \\ 200)
  defp eventually(check, 0), do: assert(check.())

  defp eventually(check, attempts) do
    unless check.() do
      Process.sleep(5)
      eventually(check, attempts - 1)
    end
  end
end
