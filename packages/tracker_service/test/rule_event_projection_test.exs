defmodule Wotex.Tracker.Service.RuleEventProjectionTest do
  @moduledoc false
  use ExUnit.Case, async: true
  import Wotex.Tracker.Service.Fixtures

  alias Exqlite.Sqlite3
  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.{Codec, RuleEventProjection, RuleFixtures, Store}

  test "public rule events omit capture, evidence and sample references", c do
    {:ok, %{"stream_cursor" => stream}} =
      Service.list(c.service, c.reader, c.scope, "rules", %{}, c.now)

    RuleFixtures.commit_all(c.store, c.scope)

    assert {:ok, %{"items" => items} = page} =
             Service.events(c.service, c.reader, c.scope, stream, c.now)

    events = Enum.map(items, & &1["event"]["data"])

    assert Enum.map(events, & &1["kind"]) == [
             "heartbeat.overdue",
             "battery.low",
             "transport.degraded",
             "trip.started",
             "geofence.entered"
           ]

    encoded = Codec.encode!(page)

    for private <-
          ~w(capture _evidence_id _observation_id _sample_identity _bundle_identity _observation_identity _decision_identity) do
      refute encoded =~ private
    end

    for event <- events do
      assert {:ok, intent} = Store.rule_event(c.store, c.scope, event["id"])
      assert event == RuleEventProjection.public(intent["event"])
      assert Map.take(intent["event"], Map.keys(event)) == event
    end

    heartbeat = hd(events)

    assert %{"rule_id" => "silence", "from_status" => "current", "to_status" => "overdue"} =
             heartbeat
  end

  test "schema four removes private references from stored public rule events" do
    directory = directory()
    path = Path.join(directory, "tracker.db")
    {:ok, db} = Sqlite3.open(path)
    schema = File.read!(Application.app_dir(:wotex_tracker_service, "priv/schema/4.sql"))
    :ok = Sqlite3.execute(db, schema)

    private = Map.new(RuleEventProjection.private_fields(), &{&1, "private"})
    event = Map.merge(private, %{"id" => "event", "kind" => "heartbeat.overdue"})
    other = %{"type" => "thing.changed", "data" => %{"id" => "thing", "to_evidence_id" => "kept"}}

    insert =
      "INSERT INTO events(scope,generation,created_at,document) VALUES('existing',1,1,?1)," <>
        "('existing',1,1,?2)"

    {:ok, statement} = Sqlite3.prepare(db, insert)

    :ok =
      Sqlite3.bind(statement, [
        Codec.encode!(%{"type" => "tracker.event", "data" => event}),
        Codec.encode!(other)
      ])

    :done = Sqlite3.step(db, statement)
    :ok = Sqlite3.release(db, statement)
    :ok = Sqlite3.execute(db, "INSERT INTO scopes VALUES('existing',1)")
    :ok = Sqlite3.close(db)
    :ok = File.chmod(path, 0o600)

    {store, _} = store(directory: directory)
    assert {:ok, %{"schema" => "5"}} = Store.readiness(store)

    assert {:ok, %{"items" => [first, second]}} =
             Store.events(store, replay(%{scope: "existing", now: 1}))

    assert first["event"] == %{
             "type" => "tracker.event",
             "data" => %{"id" => "event", "kind" => "heartbeat.overdue"}
           }

    assert second["event"] == other
  end

  setup do
    service()
  end
end
