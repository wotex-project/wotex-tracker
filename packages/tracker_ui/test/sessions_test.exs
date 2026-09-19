defmodule Wotex.Tracker.UI.SessionsTest do
  @moduledoc false
  use ExUnit.Case, async: true
  import Wotex.Tracker.Service.Fixtures
  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.Identifier
  alias Wotex.Tracker.UI.{Local, Presenter, SessionCustodian, Sessions}

  defmodule Custodian do
    @behaviour Wotex.Tracker.UI.SessionCustodian

    @impl true
    def retain(agent, credential), do: invoke(agent, :retained, credential)

    @impl true
    def release(agent, credential), do: invoke(agent, :released, credential)

    defp invoke(agent, event, credential) do
      case Agent.get(agent, & &1.mode) do
        :ok ->
          Agent.update(agent, &Map.update!(&1, event, fn values -> [credential | values] end))

        :error ->
          {:error, :unavailable}

        :raise ->
          raise "private custodian failure"

        :throw ->
          throw(:private_custodian_failure)
      end
    end
  end

  test "bounded sessions expire on monotonic time and do not cross instances" do
    c = service()
    clock = start_supervised!({Agent, fn -> 0 end})

    options = [
      client: {Local, fn -> {:ok, c.service} end},
      clock: fn -> c.now end,
      monotonic: fn -> Agent.get(clock, & &1) end,
      capacity: 1,
      ttl: 10
    ]

    first = start_supervised!({Sessions, options})
    second = start_supervised!(Supervisor.child_spec({Sessions, options}, id: :other))
    {:ok, %{"id" => id}} = Sessions.login(first, c.admin, c.scope)
    assert {:error, %{"code" => "capacity"}} = Sessions.login(first, c.admin, c.scope)
    assert {:error, %{"code" => "unauthorized"}} = Sessions.request(second, id, :authorize)
    refute inspect(:sys.get_status(first)) =~ c.admin
    Agent.update(clock, fn _ -> 10 end)
    assert {:error, %{"code" => "unauthorized"}} = Sessions.request(first, id, :authorize)
    assert {:ok, _} = Sessions.login(first, c.admin, c.scope)
  end

  test "durable service revocation invalidates existing presentation sessions" do
    c = service()

    sessions =
      start_supervised!(
        {Sessions, client: {Local, fn -> {:ok, c.service} end}, clock: fn -> c.now end}
      )

    {:ok, %{"id" => id}} = Sessions.login(sessions, c.reader, c.scope)

    assert {:ok, _} =
             Service.revoke(
               c.service,
               c.admin,
               c.scope,
               Identifier.uuid(),
               %{"credential_id" => "reader", "expected_generation" => "0"},
               c.now
             )

    assert {:error, %{"code" => "unauthorized"}} =
             Sessions.request(sessions, id, :list, %{"resource" => "observations"})

    assert {:error, %{"code" => "unauthorized"}} = Sessions.request(sessions, id, :authorize)
  end

  test "sessions list and end only browser sessions of the same credential" do
    c = service()

    sessions =
      start_supervised!(
        {Sessions, client: {Local, fn -> {:ok, c.service} end}, clock: fn -> c.now end}
      )

    {:ok, %{"id" => first}} = Sessions.login(sessions, c.admin, c.scope)
    {:ok, %{"id" => second}} = Sessions.login(sessions, c.admin, c.scope)
    {:ok, %{"id" => reader}} = Sessions.login(sessions, c.reader, c.scope)

    assert {:ok, %{"items" => items}} = Sessions.list(sessions, first)
    assert length(items) == 2
    assert [%{"handle" => current}] = Enum.filter(items, & &1["current"])
    assert [%{"handle" => other}] = Enum.reject(items, & &1["current"])

    assert Enum.all?(
             items,
             &(&1["started_at"] == c.now and &1["expires_at"] == c.now + 3_600_000)
           )

    for secret <- [first, second, reader, c.admin, c.reader] do
      refute inspect(items) =~ secret
    end

    assert {:ok, %{"items" => [%{"handle" => reader_handle}]}} = Sessions.list(sessions, reader)

    for {id, handle} <- [
          {reader, other},
          {first, reader_handle},
          {first, current},
          {first, "missing"}
        ] do
      assert {:error, %{"code" => "not_found"}} = Sessions.end_session(sessions, id, handle)
    end

    assert :ok = Sessions.end_session(sessions, first, other)
    assert {:error, %{"code" => "unauthorized"}} = Sessions.request(sessions, second, :authorize)
    assert {:ok, _} = Sessions.request(sessions, first, :authorize)
    assert {:ok, %{"items" => [%{"current" => true}]}} = Sessions.list(sessions, first)
    assert {:error, %{"code" => "unauthorized"}} = Sessions.list(sessions, "missing")

    assert {:error, %{"code" => "unauthorized"}} =
             Sessions.end_session(sessions, "missing", current)
  end

  test "optional host custody is atomic with login, restore and logout" do
    c = service()
    custodian = start_supervised!({Agent, fn -> custody() end})

    sessions =
      start_supervised!(
        {Sessions,
         client: {Local, fn -> {:ok, c.service} end},
         clock: fn -> c.now end,
         capacity: 1,
         custodian: {Custodian, custodian}}
      )

    assert {:ok, %{"id" => first}} = Sessions.login(sessions, c.admin, c.scope)
    assert [retained] = Agent.get(custodian, & &1.retained)
    assert retained.session_id == first
    assert retained.token == c.admin
    assert retained.scope == c.scope
    assert retained.access["credential_id"] == "admin"
    assert retained.access["principal"] == "owner"

    assert :ok = Sessions.logout(sessions, first)
    assert [released] = Agent.get(custodian, & &1.released)
    assert released.session_id == first

    Agent.update(custodian, &%{&1 | mode: :error})

    assert {:error, %{"code" => "storage_unavailable"}} =
             Sessions.login(sessions, c.admin, c.scope)

    Agent.update(custodian, &%{&1 | mode: :ok})

    assert {:ok, %{"id" => restored, "access" => access}} =
             Sessions.restore(sessions, c.admin, c.scope)

    assert access["credential_id"] == "admin"
    assert length(Agent.get(custodian, & &1.retained)) == 1
    assert :ok = Sessions.logout(sessions, restored)
    assert length(Agent.get(custodian, & &1.released)) == 2

    assert {:ok, %{"id" => cached, "access" => ^access}} =
             Sessions.restore_cached(sessions, c.admin, c.scope, access)

    assert {:ok, _} = Sessions.request(sessions, cached, :authorize)
    assert :ok = Sessions.discard(sessions, cached)

    assert {:error, %{"code" => "unauthorized"}} =
             Sessions.restore_cached(sessions, c.admin, "other", access)

    assert {:ok, %{"id" => retry}} = Sessions.login(sessions, c.admin, c.scope)
    Agent.update(custodian, &%{&1 | mode: :error})

    assert {:error, %{"code" => "storage_unavailable"}} = Sessions.logout(sessions, retry)
    assert {:ok, _} = Sessions.request(sessions, retry, :authorize)

    Agent.update(custodian, &%{&1 | mode: :ok})
    assert :ok = Sessions.discard(sessions, retry)
    assert {:error, %{"code" => "unauthorized"}} = Sessions.request(sessions, retry, :authorize)
    assert :ok = Sessions.discard(sessions, nil)
    assert :error = SessionCustodian.retain(:invalid, %{})

    for mode <- [:raise, :throw] do
      Agent.update(custodian, &%{&1 | mode: mode})

      assert {:error, %{"code" => "storage_unavailable"}} =
               Sessions.login(sessions, c.admin, c.scope)
    end
  end

  test "display helpers preserve unavailable, false, zero and wide integers" do
    assert Presenter.scalar(%{"value" => nil}) == "Unavailable"
    assert Presenter.scalar(%{"value" => false}) == "false"
    assert Presenter.scalar(%{"value" => 0}) == "0"
    assert Presenter.scalar(%{"value" => "9007199254740993"}) == "9007199254740993"
    assert Presenter.timestamp(nil) == "Unknown time"
    assert Presenter.timestamp(%{"value" => 999_999_999_999_999_999}) == "Unknown time"
    assert Presenter.timestamp(%{"value" => 0}, 330) == "1970-01-01 05:30:00 UTC+05:30"
    assert Presenter.timestamp(%{"value" => 0}, -480) == "1969-12-31 16:00:00 UTC-08:00"
    assert Presenter.timestamp(%{"value" => 0}, 841) == "Unknown time"
    assert Presenter.scalar(%{}) == "Unknown"
    assert Presenter.error(nil) == "The service is unavailable."
    assert Presenter.path(:asset, "urn:uuid:asset") == "/assets/urn%3Auuid%3Aasset"
  end

  test "failed providers, unsupported intents and malformed logins fail without retaining credentials" do
    provider = fn -> {:error, :offline} end

    assert {:error, %{"code" => "storage_unavailable"}} =
             Local.request(provider, "", "", :authorize, %{}, 0)

    assert {:error, %{"code" => "storage_unavailable"}} =
             Local.request(fn -> exit(:offline) end, "", "", :authorize, %{}, 0)

    c = service()

    assert {:error, %{"code" => "unsupported"}} =
             Local.request(fn -> {:ok, c.service} end, c.admin, c.scope, :arbitrary, %{}, c.now)

    assert {:error, :invalid_configuration} = Sessions.start_link([])

    for options <- [
          nil,
          [:invalid],
          [client: {String, nil}],
          [client: {Local, provider}, capacity: 0],
          [client: {Local, provider}, capacity: 4097],
          [client: {Local, provider}, ttl: 0],
          [client: {Local, provider}, ttl: 3_600_001],
          [client: {Local, provider}, custodian: {String, nil}],
          [client: {Local, provider}, ttl: 1, ttl: 2],
          [client: {Local, provider}, unexpected: true]
        ] do
      assert {:error, :invalid_configuration} = Sessions.start_link(options)
    end

    sessions =
      start_supervised!(
        {Sessions, client: {Local, fn -> {:ok, c.service} end}, clock: fn -> c.now end}
      )

    assert {:error, %{"code" => "unauthorized"}} = Sessions.login(sessions, nil, c.scope)
    assert {:error, %{"code" => "unauthorized"}} = Sessions.restore(sessions, nil, c.scope)

    assert {:error, %{"code" => "unauthorized"}} =
             Sessions.restore(sessions, "invalid-token", c.scope)

    assert {:error, %{"code" => "unauthorized"}} =
             Sessions.login(sessions, String.duplicate("x", 257), c.scope)

    assert {:error, %{"code" => "unauthorized"}} =
             Sessions.restore(sessions, String.duplicate("x", 257), c.scope)

    send(sessions, :expire)
    {:ok, %{"id" => id}} = Sessions.login(sessions, c.admin, c.scope)

    assert {:ok, _} =
             Sessions.request(sessions, id, :submit, %{
               "operation" => Identifier.uuid(),
               "request" => import_request()
             })

    GenServer.stop(sessions)

    assert {:error, %{"code" => "storage_unavailable"}} =
             Sessions.request(sessions, id, :authorize)

    assert {:error, %{"code" => "storage_unavailable"}} =
             Sessions.login(sessions, c.admin, c.scope)

    assert {:error, %{"code" => "storage_unavailable"}} =
             Sessions.restore(sessions, c.admin, c.scope)

    assert :ok = Sessions.logout(sessions, id)
    assert :ok = Sessions.discard(sessions, id)
  end

  defp custody, do: %{mode: :ok, retained: [], released: []}
end
