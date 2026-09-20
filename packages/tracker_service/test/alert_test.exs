defmodule Wotex.Tracker.Service.AlertTest do
  @moduledoc false
  use ExUnit.Case, async: true
  import Wotex.Tracker.Service.Fixtures

  alias Exqlite.Sqlite3
  alias Wotex.Tracker.HeartbeatTransition
  alias Wotex.Tracker.Service

  alias Wotex.Tracker.Service.{
    Alert,
    Codec,
    Identifier,
    RuleEventProjection,
    RuleFixtures,
    RuleTransition,
    Store
  }

  test "rule events become newest-first alerts and a live alert is acknowledged once" do
    c = service()
    RuleFixtures.commit_all(c.store, c.scope)

    assert {:ok, %{"items" => items, "generation" => "11"} = page} =
             Service.list(c.service, c.reader, c.scope, "alerts", %{}, c.now)

    assert Enum.map(items, &{&1["value"]["event"]["kind"], &1["value"]["generation"]}) == [
             {"geofence.entered", "11"},
             {"trip.started", "9"},
             {"transport.degraded", "6"},
             {"battery.low", "4"},
             {"heartbeat.overdue", "2"}
           ]

    heartbeat = List.last(items)["value"]
    {:ok, intent} = Store.rule_event(c.store, c.scope, heartbeat["event_id"])

    assert heartbeat == %{
             "schema" => "wtr.alert.v1",
             "id" => Alert.id(2, intent["event_id"]),
             "event_id" => intent["event_id"],
             "event" => RuleEventProjection.public(intent["event"]),
             "rule" => %{"kind" => "heartbeat", "id" => "silence"},
             "thing_id" => nil,
             "mode" => "live",
             "physical_action_dispatch" => "separate_authorization_required",
             "created_at" => RuleFixtures.now() + 11,
             "generation" => "2",
             "acknowledgement" => nil
           }

    for private <- ~w(capture _evidence_id _observation_id _sample_identity acknowledged_by) do
      refute Codec.encode!(page) =~ private
    end

    geofence = hd(items)["id"]
    request = %{"alert_id" => geofence, "expected_generation" => "11"}
    operation = Identifier.uuid()

    assert {:error, %{"code" => "forbidden"}} = acknowledge(c, c.reader, request)

    {:ok, %{"stream_cursor" => stream}} =
      Service.list(c.service, c.reader, c.scope, "alerts", %{}, c.now)

    assert {:ok, %{"generation" => "12", "data" => data} = receipt} =
             Service.acknowledge_alert(c.service, c.admin, c.scope, operation, request, c.now + 5)

    assert data == %{"alert_id" => geofence, "action" => "acknowledged"}

    assert {:ok, ^receipt} =
             Service.acknowledge_alert(c.service, c.admin, c.scope, operation, request, c.now + 6)

    assert {:ok, %{"value" => acknowledged}} =
             Service.get(c.service, c.reader, c.scope, "alerts", geofence, c.now)

    assert %{"at" => at, "by" => "wtr1_" <> _} = acknowledged["acknowledgement"]
    assert at == c.now + 5
    refute Map.has_key?(acknowledged, "acknowledged_by")

    assert {:error, %{"code" => "conflict"}} =
             acknowledge(c, c.admin, %{request | "expected_generation" => "12"})

    battery = Enum.at(items, 3)["id"]

    assert {:error, %{"code" => "conflict"}} =
             acknowledge(c, c.admin, %{"alert_id" => battery, "expected_generation" => "11"})

    assert {:error, %{"code" => "not_found"}} =
             acknowledge(c, c.admin, %{
               "alert_id" => "alert-missing",
               "expected_generation" => "12"
             })

    assert {:error, %{"code" => "invalid_request"}} =
             acknowledge(c, c.admin, %{"alert_id" => battery})

    assert {:error, %{"code" => "conflict"}} =
             acknowledge(c, c.admin, %{"alert_id" => battery, "expected_generation" => "99"})

    assert {:ok, %{"items" => [%{"event" => event}]}} =
             Service.events(c.service, c.reader, c.scope, stream, c.now)

    assert event == %{"type" => "alert.acknowledged", "data" => %{"id" => geofence}}

    assert {:ok, %{"items" => [%{"value" => %{"acknowledgement" => nil}}, _]}} =
             Service.history(c.service, c.reader, c.scope, "alerts", geofence, %{}, c.now)
  end

  test "replayed events are informational alerts that cannot be acknowledged" do
    c = service()
    policy = RuleFixtures.heartbeat_policy()
    capture = observation(%{id: "capture", observed_at: c.now})
    {:ok, baseline} = HeartbeatTransition.evaluate(nil, capture, policy, :replay, c.now)
    {:ok, first} = RuleTransition.new(c.scope, nil, baseline)
    {:ok, _} = Store.commit_rule(c.store, first)
    state = baseline["state"]

    {:ok, overdue} = HeartbeatTransition.evaluate(state, nil, policy, :replay, state.due_at)
    {:ok, second} = RuleTransition.new(c.scope, state, overdue)
    {:ok, _} = Store.commit_rule(c.store, second)

    assert {:ok, %{"items" => [%{"id" => id, "value" => alert}]}} =
             Service.list(c.service, c.reader, c.scope, "alerts", %{}, c.now)

    assert %{"mode" => "replay", "physical_action_dispatch" => "prohibited"} = alert

    assert {:error, %{"code" => "conflict"}} =
             acknowledge(c, c.admin, %{"alert_id" => id, "expected_generation" => "2"})
  end

  test "schema five backfills alerts identical to newly written records" do
    written = service()
    RuleFixtures.commit_heartbeat(written.store, written.scope)

    {:ok, %{"items" => [%{"id" => id, "value" => expected}]}} =
      Service.list(written.service, written.reader, written.scope, "alerts", %{}, written.now)

    {:ok, intent} = Store.rule_event(written.store, written.scope, expected["event_id"])

    directory = directory()
    path = Path.join(directory, "tracker.db")
    {:ok, db} = Sqlite3.open(path)

    :ok =
      Sqlite3.execute(
        db,
        File.read!(Application.app_dir(:wotex_tracker_service, "priv/schema/5.sql"))
      )

    {:ok, statement} =
      Sqlite3.prepare(
        db,
        "INSERT INTO rule_event_intents VALUES('existing',?1,'digest','heartbeat','silence',2,?2,?3,'live','separate_authorization_required')"
      )

    :ok =
      Sqlite3.bind(statement, [
        intent["event_id"],
        intent["created_at"],
        Codec.encode!(intent["event"])
      ])

    :done = Sqlite3.step(db, statement)
    :ok = Sqlite3.release(db, statement)
    :ok = Sqlite3.execute(db, "INSERT INTO scopes VALUES('existing',2)")
    :ok = Sqlite3.close(db)
    :ok = File.chmod(path, 0o600)

    {store, _} = store(directory: directory)
    assert {:ok, %{"schema" => "9"}} = Store.readiness(store)

    assert {:ok, %{"items" => [%{"id" => ^id, "generation" => "2", "value" => migrated}]}} =
             Store.snapshot(store, query(%{scope: "existing", kind: "alerts"}))

    assert migrated == %{"public" => expected}
  end

  test "schema six binds existing alerts to the Thing of a same-kind definition" do
    directory = directory()
    path = Path.join(directory, "tracker.db")
    {:ok, db} = Sqlite3.open(path)

    :ok =
      Sqlite3.execute(
        db,
        File.read!(Application.app_dir(:wotex_tracker_service, "priv/schema/6.sql"))
      )

    thing = "urn:uuid:" <> Identifier.uuid()

    alert = fn kind, id ->
      Codec.encode!(%{"public" => %{"rule" => %{"kind" => kind, "id" => id}}})
    end

    policy = Codec.encode!(%{"public" => %{"kind" => "battery", "thing_id" => thing}})

    for {kind, id, generation, document} <- [
          {"policies", "low-battery", 1, policy},
          {"policies", "low-battery", 2, "null"},
          {"alerts", "alert-2", 2, alert.("battery", "low-battery")},
          {"alerts", "alert-3", 3, alert.("heartbeat", "low-battery")},
          {"alerts", "alert-4", 4, alert.("heartbeat", "silence")}
        ] do
      {:ok, statement} = Sqlite3.prepare(db, "INSERT INTO records VALUES('existing',?1,?2,?3,?4)")
      :ok = Sqlite3.bind(statement, [kind, id, generation, document])
      :done = Sqlite3.step(db, statement)
      :ok = Sqlite3.release(db, statement)
    end

    :ok = Sqlite3.execute(db, "INSERT INTO scopes VALUES('existing',4)")
    :ok = Sqlite3.close(db)
    :ok = File.chmod(path, 0o600)

    {store, _} = store(directory: directory)
    assert {:ok, %{"schema" => "9"}} = Store.readiness(store)

    assert {:ok, %{"items" => items}} =
             Store.snapshot(store, query(%{scope: "existing", kind: "alerts"}))

    assert Enum.map(items, &{&1["id"], &1["value"]["public"]["thing_id"]}) == [
             {"alert-2", thing},
             {"alert-3", nil},
             {"alert-4", nil}
           ]

    assert Enum.all?(items, &Map.has_key?(&1["value"]["public"], "thing_id"))
  end

  defp acknowledge(c, token, request),
    do: Service.acknowledge_alert(c.service, token, c.scope, Identifier.uuid(), request, c.now)
end
