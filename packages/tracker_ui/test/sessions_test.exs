defmodule Wotex.Tracker.UI.SessionsTest do
  @moduledoc false
  use ExUnit.Case, async: true
  import Wotex.Tracker.Service.Fixtures
  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.Identifier
  alias Wotex.Tracker.UI.{Local, Presenter, Sessions}

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

  test "display helpers preserve unavailable, false, zero and wide integers" do
    assert Presenter.scalar(%{"value" => nil}) == "Unavailable"
    assert Presenter.scalar(%{"value" => false}) == "false"
    assert Presenter.scalar(%{"value" => 0}) == "0"
    assert Presenter.scalar(%{"value" => "9007199254740993"}) == "9007199254740993"
    assert Presenter.timestamp(nil) == "Unknown time"
    assert Presenter.timestamp(%{"value" => 999_999_999_999_999_999}) == "Unknown time"
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

    assert {:error, %{"code" => "unauthorized"}} =
             Sessions.login(sessions, String.duplicate("x", 257), c.scope)

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

    assert :ok = Sessions.logout(sessions, id)
  end
end
