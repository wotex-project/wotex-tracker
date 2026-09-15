defmodule Wotex.Tracker.HistoryTest do
  @moduledoc false
  use ExUnit.Case, async: true
  import Wotex.Tracker.Service.Fixtures
  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.{Codec, Identifier, Store}

  test "history pages hold a committed snapshot across later writes and hand off to exact events" do
    c = service()
    {thing, td} = materialized(c)
    rematerialize(c, thing, "3")
    {:ok, %{"value" => td4}} = Service.get(c.service, c.reader, c.scope, "things", thing, c.now)
    assert {:ok, first} = history(c, "things", thing, %{"limit" => 1})
    assert first["generation"] == "4"
    assert [%{"generation" => "3", "deleted" => false, "value" => ^td}] = first["items"]
    assert is_binary(first["cursor"])
    rematerialize(c, thing, "4")
    assert {:ok, second} = history(c, "things", thing, %{"cursor" => first["cursor"]})
    assert second["generation"] == "4"
    assert [%{"generation" => "4", "value" => ^td4}] = second["items"]
    assert second["cursor"] == nil

    assert {:ok, %{"items" => [%{"generation" => "5", "event" => %{"type" => "thing.changed"}}]}} =
             Service.events(c.service, c.reader, c.scope, second["stream_cursor"], c.now)

    assert {:ok, latest} = history(c, "things", thing)
    assert Enum.map(latest["items"], & &1["generation"]) == ["3", "4", "5"]
    assert latest["cursor"] == nil
    assert {:ok, states} = history(c, "state", thing)
    assert length(states["items"]) == 3

    assert {:ok, enrollment} =
             Service.get(c.service, c.reader, c.scope, "enrollments", thing, c.now)

    observation = enrollment["value"]["observation_id"]

    for resource <- ["observations", "resolutions", "evidence"] do
      assert {:ok, page} = history(c, resource, observation)
      assert length(page["items"]) == 1
      bytes = Codec.encode!(page)

      for private <- ["private-hardware", "private-receiver", "observation-1", "cbb8334c884f"],
          do: refute(bytes =~ private)
    end

    GenServer.stop(c.store.pid)
    {store, _} = store(directory: c.directory, credentials: c.credentials)
    restarted = %{c | service: %{c.service | store: store}, store: store}
    assert {:ok, resumed} = history(restarted, "things", thing, %{"cursor" => first["cursor"]})
    assert resumed["items"] == second["items"]
  end

  test "history cursors bind resource, identity, authority and page size and never skip expiry" do
    c = service()
    {thing, _} = materialized(c)
    rematerialize(c, thing, "3")
    {:ok, first} = history(c, "things", thing, %{"limit" => 1})
    params = %{"cursor" => first["cursor"]}

    for {context, resource, id, params} <- [
          {c, "state", thing, params},
          {c, "things", "different", params},
          {c, "things", thing, Map.put(params, "limit", 2)},
          {%{c | reader: c.admin}, "things", thing, params},
          {c, "things", thing, %{"cursor" => first["stream_cursor"]}}
        ] do
      assert {:error, %{"code" => "invalid_cursor"}} = history(context, resource, id, params)
    end

    assert {:error, %{"code" => "invalid_cursor"}} =
             Service.list(c.service, c.reader, c.scope, "things", params, c.now)

    assert {:error, %{"code" => "invalid_cursor"}} =
             Service.events(c.service, c.reader, c.scope, first["cursor"], c.now)

    assert {:error, %{"code" => "cursor_expired"}} =
             history(%{c | now: c.now + 604_800_000}, "things", thing, params)

    assert {:error, %{"code" => "not_found"}} = history(c, "things", "missing")
    assert {:error, %{"code" => "unsupported"}} = history(c, "access", thing)
    assert {:error, %{"code" => "invalid_request"}} = history(c, "things", "")

    for params <- [
          nil,
          %{"query" => "arbitrary SQL"},
          %{"limit" => 0},
          %{"limit" => 101},
          %{"limit" => "1"}
        ] do
      assert {:error, %{"code" => "invalid_request"}} = history(c, "things", thing, params)
    end

    assert {:ok, _} =
             Service.revoke(
               c.service,
               c.admin,
               c.scope,
               Identifier.uuid(),
               %{"credential_id" => "reader", "expected_generation" => "4"},
               c.now
             )

    assert {:error, %{"code" => "unauthorized"}} = history(c, "things", thing, params)
  end

  test "the store keeps deletion tombstones and bounds and validates historical queries" do
    {store, _} = store()
    assert {:ok, _} = Store.mutate(store, update())

    assert {:ok, _} =
             Store.mutate(
               store,
               update(%{
                 operation_id: "delete",
                 expected_generation: "1",
                 observation: nil,
                 records: [%{kind: "state", id: "sensor", value: nil}]
               })
             )

    query = %{
      scope: "workshop",
      kind: "state",
      id: "sensor",
      generation: nil,
      after: "0",
      limit: 100
    }

    assert {:ok, page} = Store.history(store, query)
    assert [%{"deleted" => false}, %{"deleted" => true, "value" => nil}] = page["items"]
    assert {:ok, %{"items" => []}} = Store.history(store, %{query | after: "2"})

    for changes <- [%{generation: "3"}, %{after: "3"}] do
      assert {:error, :invalid_cursor} = Store.history(store, Map.merge(query, changes))
    end

    for invalid <- [
          nil,
          %{},
          %{query | limit: 0},
          %{query | generation: "01"},
          %{query | after: "-1"},
          %{query | id: ""},
          Map.put(query, :extra, true)
        ] do
      assert {:error, :invalid_query} = Store.history(store, invalid)
    end
  end

  test "public history preserves a deleted version and reauthorizes the store query" do
    c = service()
    {thing, _} = materialized(c)
    {:ok, access} = Service.authorize(c.service, c.admin, c.scope, "read", c.now)

    assert {:ok, _} =
             Store.mutate(
               c.store,
               update(%{
                 principal: access.principal,
                 authority: access,
                 operation_id: Identifier.uuid(),
                 expected_generation: "3",
                 observation: nil,
                 records: [%{kind: "state", id: thing, value: nil}]
               })
             )

    assert {:ok, page} = history(c, "state", thing)

    assert [%{"deleted" => false}, %{"deleted" => true, "value" => nil, "generation" => "4"}] =
             page["items"]

    query = %{scope: c.scope, kind: "state", id: thing, generation: nil, after: "0", limit: 100}
    assert {:error, :unauthorized} = Store.authorized_history(c.store, nil, query, c.now)
    GenServer.stop(c.store.pid)
    assert {:error, %{"code" => "storage_unavailable"}} = history(c, "state", thing)
  end

  test "a caller must reduce the page size when retained versions exceed the response byte ceiling" do
    {store, _} = store()

    for generation <- 0..19 do
      assert {:ok, _} =
               Store.mutate(
                 store,
                 update(%{
                   operation_id: "large-#{generation}",
                   expected_generation: Integer.to_string(generation),
                   observation: nil,
                   records: [
                     %{
                       kind: "state",
                       id: "large",
                       value: %{"blob" => String.duplicate("a", 220_000)}
                     }
                   ]
                 })
               )
    end

    query = %{
      scope: "workshop",
      kind: "state",
      id: "large",
      generation: nil,
      after: "0",
      limit: 100
    }

    assert {:error, :response_too_large} = Store.history(store, query)
    assert {:ok, %{"next" => "1", "items" => [_]}} = Store.history(store, %{query | limit: 1})
  end

  defp history(c, resource, id, params \\ %{}),
    do: Service.history(c.service, c.reader, c.scope, resource, id, params, c.now)

  defp rematerialize(c, thing, generation) do
    assert {:ok, _} =
             Service.materialize(
               c.service,
               c.admin,
               c.scope,
               Identifier.uuid(),
               %{"thing_id" => thing, "expected_generation" => generation},
               c.now
             )
  end
end
