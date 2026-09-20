defmodule Wotex.Tracker.Service.StoreTest do
  @moduledoc false

  use ExUnit.Case, async: true
  import Wotex.Tracker.Service.Fixtures

  alias Exqlite.Sqlite3
  alias Wotex.Tracker.Observation
  alias Wotex.Tracker.Service.{Codec, Store}

  test "commits observation, state, dedupe and event at one generation; native types survive restart" do
    {store, directory} = store()

    value = %{
      "integer" => 1,
      "float" => 1.0,
      "wide" => 9_007_199_254_740_993,
      "zero" => 0,
      "false" => false,
      "nil" => nil
    }

    update = update(%{records: [%{kind: "state", id: "sensor", value: value}]})
    assert {:ok, result} = Store.mutate(store, update)
    assert result["outcome"] == "committed"
    assert result["generation"] == "1"
    assert Store.mutate(store, update) == {:ok, result}

    assert Store.operation(store, "workshop", "operator", "operation-1", update.now) ==
             {:ok, result}

    assert {:ok, %{"items" => [%{"value" => ^value}], "event_cursor" => "1"}} =
             Store.snapshot(store, query())

    assert {:ok, %{"items" => [%{"value" => document}]}} =
             Store.snapshot(store, query(%{kind: "observations"}))

    assert {:ok, original} = Observation.from_map(document)
    assert original === update.observation
    assert {:ok, %{"sqlite" => "3.53.4", "writable" => true}} = Store.readiness(store)
    GenServer.stop(store.pid)
    {reopened, _} = store(directory: directory)
    assert Store.mutate(reopened, update) == {:ok, result}
    assert {:ok, %{"items" => [_]}} = Store.events(reopened, replay())
  end

  test "operation identity is scoped, strict, conditional and retained after expiry" do
    {store, _} = store()
    assert {:ok, _} = Store.mutate(store, update(%{request: %{"value" => 1}}))

    assert {:error, :idempotency_conflict} =
             Store.mutate(store, update(%{request: %{"value" => 1.0}}))

    assert {:error, :conflict} = Store.mutate(store, update(%{principal: "other"}))
    assert {:ok, %{"generation" => "1"}} = Store.mutate(store, update(%{scope: "other"}))
    assert {:error, :not_found} = Store.operation(store, "workshop", "other", "operation-1", 0)
    assert {:error, :invalid_query} = Store.operation(store, "", "operator", "operation-1", -1)
    expires = 1_700_000_000_000 + 604_800_000

    assert {:error, :operation_expired} =
             Store.operation(store, "workshop", "operator", "operation-1", expires)

    assert {:error, :operation_expired} =
             Store.mutate(store, update(%{request: %{"value" => 1}, now: expires}))
  end

  test "a repeated observation under a new operation records no new live effect" do
    {store, _} = store()
    assert {:ok, _} = Store.mutate(store, update())

    assert {:ok, %{"generation" => "1", "disposition" => "duplicate", "publication" => nil}} =
             Store.mutate(store, update(%{operation_id: "retry", expected_generation: "1"}))

    assert {:error, :observation_conflict} =
             Store.mutate(
               store,
               update(%{
                 operation_id: "changed",
                 expected_generation: "1",
                 observation: observation(%{radio: %{"rssi" => -71}})
               })
             )

    assert {:ok, %{"items" => [_]}} = Store.events(store, replay())
  end

  test "independent SQLite writers race duplicate requests and conditional updates" do
    {first, directory} = store()
    {second, _} = store(directory: directory)

    results =
      [first, second]
      |> Enum.map(&Task.async(fn -> Store.mutate(&1, update()) end))
      |> Task.await_many()

    assert [{:ok, result}, {:ok, result}] = results
    different = update(%{operation_id: "next", expected_generation: "1", observation: nil})

    results =
      [{first, different}, {second, %{different | operation_id: "competitor"}}]
      |> Enum.map(fn {store, update} -> Task.async(fn -> Store.mutate(store, update) end) end)
      |> Task.await_many()

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert {:error, :conflict} in results
    assert {:ok, %{"items" => [_, _]}} = Store.events(first, replay())
  end

  test "snapshots, pagination, tombstones and stream handoff cannot mix commits" do
    {store, _} = store()

    assert {:ok, _} =
             Store.mutate(
               store,
               update(%{
                 records: [
                   %{kind: "state", id: "a", value: 1},
                   %{kind: "state", id: "b", value: 2}
                 ]
               })
             )

    assert {:ok,
            %{
              "generation" => "1",
              "event_cursor" => cursor,
              "next" => "a",
              "items" => [%{"id" => "a"}]
            }} = Store.snapshot(store, query(%{limit: 1}))

    assert {:ok, _} =
             Store.mutate(
               store,
               update(%{
                 operation_id: "next",
                 expected_generation: "1",
                 observation: nil,
                 records: [
                   %{kind: "state", id: "b", value: nil},
                   %{kind: "state", id: "c", value: 3}
                 ]
               })
             )

    assert {:ok, %{"items" => [%{"id" => "b", "value" => 2}], "event_cursor" => ^cursor}} =
             Store.snapshot(store, query(%{generation: "1", after: "a"}))

    assert {:ok, %{"items" => [%{"id" => "a"}, %{"id" => "c"}]}} = Store.snapshot(store, query())

    assert {:ok, %{"items" => [%{"generation" => "2"}], "next" => "2"}} =
             Store.events(store, replay(%{after: cursor}))

    assert {:ok, %{"items" => [], "next" => "2"}} = Store.events(store, replay(%{after: "2"}))
    assert {:error, :invalid_cursor} = Store.snapshot(store, query(%{generation: "3"}))
    assert {:error, :invalid_query} = Store.snapshot(store, query(%{generation: "01"}))
    assert {:error, :invalid_query} = Store.snapshot(store, %{})
    assert {:error, :invalid_query} = Store.events(store, %{})
    assert {:error, :invalid_query} = Store.events(store, replay(%{limit: 101}))
    assert {:error, :invalid_cursor} = Store.events(store, replay(%{scope: "other", after: "1"}))
    assert {:error, :invalid_cursor} = Store.events(store, replay(%{after: "3"}))

    assert {:error, :cursor_expired} =
             Store.events(store, replay(%{after: "1", now: 1_700_604_800_000}))

    assert {:error, :cursor_expired} = Store.events(store, replay(%{now: 1_700_604_800_000}))
  end

  test "row capacity rejects atomically and SQLite full errors leave no partial operation" do
    {small, _} = store(max_rows: 1)
    assert {:ok, _} = Store.mutate(small, update())

    assert {:error, :capacity_exceeded} =
             Store.mutate(
               small,
               update(%{operation_id: "second", expected_generation: "1", observation: nil})
             )

    {full, directory} = store(max_pages: 32)

    large =
      update(%{records: [%{kind: "state", id: "large", value: String.duplicate("x", 100_000)}]})

    assert {:error, :storage_full} = Store.mutate(full, large)

    assert {:error, :not_found} =
             Store.operation(full, "workshop", "operator", "operation-1", large.now)

    assert {:ok, %{"generation" => "0", "items" => []}} = Store.snapshot(full, query())
    assert {:ok, _} = Store.mutate(full, update())
    {:ok, db} = Sqlite3.open(Path.join(directory, "tracker.db"))
    :ok = Sqlite3.execute(db, "BEGIN IMMEDIATE")

    assert {:error, :busy} =
             Store.mutate(
               full,
               update(%{operation_id: "busy", expected_generation: "1", observation: nil})
             )

    :ok = Sqlite3.execute(db, "ROLLBACK")
    :ok = Sqlite3.close(db)
  end

  test "consistent backup includes committed WAL and can be restored offline" do
    {store, _} = store()
    assert {:ok, result} = Store.mutate(store, update())
    backup_directory = directory()
    backup = Path.join(backup_directory, "tracker.db")
    assert {:ok, %{"backup" => "complete"}} = Store.backup(store, backup)
    assert {:error, :unsafe_path} = Store.backup(store, backup)
    assert {:error, :unsafe_path} = Store.backup(store, "relative.db")
    assert {:ok, %{"busy" => 0}} = Store.checkpoint(store)
    {restored, _} = store(directory: backup_directory)
    assert Store.mutate(restored, update()) == {:ok, result}
    assert {:ok, %{"items" => [_]}} = Store.events(restored, replay())
    assert {:ok, _} = Codec.decode(Codec.encode!(result))
  end

  test "a fresh snapshot can resume a quiet scope whose last event is older than retention" do
    {store, _} = store()
    assert {:ok, _} = Store.mutate(store, update())
    now = 1_700_604_800_000
    assert {:error, :cursor_expired} = Store.events(store, replay(%{after: "1", now: now}))

    assert {:ok, %{"generation" => generation, "event_cursor" => cursor}} =
             Store.snapshot(store, query())

    handoff = replay(%{after: cursor, now: now, snapshot_generation: generation})
    assert {:ok, %{"items" => []}} = Store.events(store, handoff)
    assert {:error, :invalid_cursor} = Store.events(store, %{handoff | snapshot_generation: "2"})
    assert {:error, :invalid_cursor} = Store.events(store, %{handoff | after: "0"})
    assert {:error, :invalid_query} = Store.events(store, %{handoff | snapshot_generation: "bad"})
    assert {:error, :invalid_query} = Store.events(store, Map.put(replay(), :extra, true))

    assert {:ok, _} =
             Store.mutate(
               store,
               update(%{
                 operation_id: "later",
                 expected_generation: "1",
                 now: now,
                 observation: nil
               })
             )

    assert {:ok, %{"items" => [%{"generation" => "2"}]}} = Store.events(store, handoff)
  end

  test "oversized query responses reject explicitly without publishing a partial page" do
    {store, _} = store()

    for generation <- 0..5 do
      records =
        for index <- 1..4,
            do: %{
              kind: "state",
              id: "#{generation}-#{index}",
              value: String.duplicate("x", 190_000)
            }

      assert {:ok, _} =
               Store.mutate(
                 store,
                 update(%{
                   operation_id: "#{generation}",
                   expected_generation: "#{generation}",
                   observation: nil,
                   records: records
                 })
               )
    end

    assert {:error, :response_too_large} = Store.snapshot(store, query())
    assert {:ok, %{"items" => [_, _, _, _]}} = Store.snapshot(store, query(%{limit: 4}))
  end
end
