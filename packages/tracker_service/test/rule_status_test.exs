defmodule Wotex.Tracker.Service.RuleStatusTest do
  @moduledoc false
  use ExUnit.Case, async: true
  import Wotex.Tracker.Service.Fixtures

  alias Exqlite.Sqlite3
  alias Wotex.Tracker.{Geofence, GeofenceTransition, HeartbeatTransition, MotionTransition}
  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.{Codec, Identifier, RuleFixtures, RuleStatus}

  test "readers inspect every persisted rule kind without private evidence" do
    c = service()
    states = RuleFixtures.commit_all(c.store, c.scope)

    assert {:ok, %{"generation" => "11", "cursor" => nil, "items" => items} = page} =
             Service.list(c.service, c.reader, c.scope, "rules", %{}, c.now)

    assert Enum.map(items, &{&1["id"], &1["generation"], &1["value"]["status"]}) == [
             {"battery:low-battery", "4", "low"},
             {"geofence:yard-membership", "11", "inside"},
             {"heartbeat:silence", "2", "overdue"},
             {"motion:trips", "9", "moving"},
             {"transport_degradation:uplink", "6", "degraded"}
           ]

    heartbeat = states.heartbeat

    assert Enum.find(items, &(&1["id"] == "heartbeat:silence"))["value"] == %{
             "schema" => "wtr.rule-status.v1",
             "kind" => "heartbeat",
             "rule" => %{
               "id" => "silence",
               "revision" => "silence-v1",
               "identity" => heartbeat.policy.identity
             },
             "state_identity" => heartbeat.identity,
             "status" => "overdue",
             "heartbeat" => %{
               "observed_at" => integer(RuleFixtures.now()),
               "due_at" => integer(RuleFixtures.now() + 11),
               "evaluated_at" => integer(RuleFixtures.now() + 11),
               "maximum_silence_ms" => integer(10)
             }
           }

    assert %{
             "measurement" => %{
               "kind" => "batteryVoltage",
               "value" => %{"type" => "number", "value" => 2.5},
               "unit" => "V",
               "availability" => "available",
               "quality" => "valid",
               "reason" => "fixture"
             },
             "low_threshold" => %{"type" => "number", "value" => 2.5},
             "clear_threshold" => %{"type" => "number", "value" => 2.8},
             "accept_suspect" => false
           } = value(items, "battery:low-battery")["battery"]

    assert %{"active_trip" => %{"id" => trip}, "candidate_status" => nil} =
             value(items, "motion:trips")["motion"]

    assert trip == states.motion.active_trip.id

    assert %{
             "fence" => %{"id" => "yard", "revision" => "yard-v1"},
             "membership_reason" => "coordinate_inside"
           } = value(items, "geofence:yard-membership")["geofence"]

    assert %{"decision_status" => "unavailable", "selected_candidate_id" => nil} =
             value(items, "transport_degradation:uplink")["transport_degradation"]

    encoded = Codec.encode!(page)

    for private <- ~w(capture private-hardware private-receiver latitude longitude bundle payload) do
      refute encoded =~ private
    end

    for item <- items do
      assert {:ok, %{"id" => id, "generation" => "11", "value" => value}} =
               Service.get(c.service, c.reader, c.scope, "rules", item["id"], c.now)

      assert {id, value} == {item["id"], item["value"]}
    end
  end

  test "rule pages and history stay bound to their first committed snapshot" do
    c = service()
    RuleFixtures.commit_all(c.store, c.scope)

    assert {:ok, %{"items" => first, "cursor" => cursor, "generation" => "11"}} =
             Service.list(c.service, c.reader, c.scope, "rules", %{"limit" => 2}, c.now)

    {:ok, %{"generation" => "12"}} =
      Service.submit(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        import_request(%{}, "11"),
        c.now
      )

    assert {:ok, %{"items" => second, "cursor" => next, "generation" => "11"}} =
             Service.list(c.service, c.reader, c.scope, "rules", %{"cursor" => cursor}, c.now)

    assert {:ok, %{"items" => third, "cursor" => nil}} =
             Service.list(c.service, c.reader, c.scope, "rules", %{"cursor" => next}, c.now)

    assert length(Enum.uniq_by(first ++ second ++ third, & &1["id"])) == 5

    assert {:error, %{"code" => "invalid_cursor"}} =
             Service.list(c.service, c.reader, c.scope, "state", %{"cursor" => cursor}, c.now)

    assert {:ok, %{"items" => [baseline], "cursor" => history_cursor}} =
             Service.history(
               c.service,
               c.reader,
               c.scope,
               "rules",
               "heartbeat:silence",
               %{"limit" => 1},
               c.now
             )

    assert %{"generation" => "1", "deleted" => false, "value" => %{"status" => "current"}} =
             baseline

    assert {:ok, %{"items" => [overdue], "cursor" => nil, "generation" => "12"}} =
             Service.history(
               c.service,
               c.reader,
               c.scope,
               "rules",
               "heartbeat:silence",
               %{"cursor" => history_cursor},
               c.now
             )

    assert %{"generation" => "2", "value" => %{"status" => "overdue"}} = overdue
  end

  test "missing, revoked and corrupted rule reads fail explicitly" do
    c = service()
    RuleFixtures.commit_heartbeat(c.store, c.scope)

    assert {:error, %{"code" => "not_found"}} =
             Service.get(c.service, c.reader, c.scope, "rules", "heartbeat:missing", c.now)

    assert {:error, %{"code" => "not_found"}} =
             Service.history(c.service, c.reader, c.scope, "rules", "motion:none", %{}, c.now)

    assert {:error, %{"code" => "unauthorized"}} =
             Service.list(c.service, "invalid", c.scope, "rules", %{}, c.now)

    corrupt!(c, 1)

    assert {:ok, %{"items" => [%{"value" => %{"status" => "overdue"}}]}} =
             Service.list(c.service, c.reader, c.scope, "rules", %{}, c.now)

    assert {:error, %{"code" => "storage_unavailable"}} =
             Service.history(
               c.service,
               c.reader,
               c.scope,
               "rules",
               "heartbeat:silence",
               %{},
               c.now
             )

    corrupt!(c, 2)

    assert {:error, %{"code" => "storage_unavailable"}} =
             Service.list(c.service, c.reader, c.scope, "rules", %{}, c.now)

    assert {:error, %{"code" => "storage_unavailable"}} =
             Service.get(c.service, c.reader, c.scope, "rules", "heartbeat:silence", c.now)

    assert {:ok, %{"generation" => "3"}} =
             Service.revoke(
               c.service,
               c.admin,
               c.scope,
               Identifier.uuid(),
               %{"credential_id" => "reader", "expected_generation" => "2"},
               c.now
             )

    assert {:error, %{"code" => "unauthorized"}} =
             Service.get(c.service, c.reader, c.scope, "rules", "heartbeat:silence", c.now)
  end

  test "projection rejects foreign identifiers and documents" do
    policy = RuleFixtures.heartbeat_policy()
    capture = observation(%{id: "capture", observed_at: RuleFixtures.now()})
    {:ok, result} = HeartbeatTransition.evaluate(nil, capture, policy, :live, RuleFixtures.now())
    {:ok, document} = HeartbeatTransition.state_to_map(result["state"])

    assert {:ok, %{"status" => "current"}} = RuleStatus.project("heartbeat:silence", document)

    for {id, value} <- [
          {"silence", document},
          {"alarm:silence", document},
          {"heartbeat:other", document},
          {"battery:silence", document},
          {"heartbeat:silence", Map.put(document, "status", "overdue")},
          {nil, document}
        ] do
      assert {:error, :storage_unavailable} = RuleStatus.project(id, value)
    end
  end

  test "baselines without a trip or valid membership stay explicitly unknown" do
    now = RuleFixtures.now()
    first = RuleFixtures.position("first", 0, now)

    {:ok, motion} =
      MotionTransition.evaluate(nil, first, RuleFixtures.motion_policy(), :live, now)

    {:ok, motion_document} = MotionTransition.state_to_map(motion["state"])

    assert {:ok, %{"status" => "unknown", "motion" => %{"active_trip" => nil}}} =
             RuleStatus.project("motion:trips", motion_document)

    {:ok, bounded} =
      Geofence.new(%{
        id: "yard",
        revision: "yard-v1",
        shape: %{kind: :circle, latitude: 0, longitude: 0, radius_m: 100},
        boundary: :inside,
        uncertainty: :require_bound
      })

    {:ok, geofence} =
      GeofenceTransition.evaluate(nil, bounded, first, RuleFixtures.geofence_policy(), :live, now)

    {:ok, geofence_document} = GeofenceTransition.state_to_map(geofence["state"])

    assert {:ok,
            %{
              "status" => "unknown",
              "geofence" => %{
                "fence" => %{"revision" => "yard-v1"},
                "membership_reason" => nil,
                "membership_event_at" => nil,
                "last_received_outcome" => "accepted"
              }
            }} = RuleStatus.project("geofence:yard-membership", geofence_document)
  end

  # A second connection models on-disk damage below the transactional store API.
  defp corrupt!(context, generation) do
    {:ok, db} = Sqlite3.open(Path.join(context.directory, "tracker.db"))

    :ok =
      Sqlite3.execute(
        db,
        "UPDATE records SET document='{}' WHERE kind='rules' AND generation=#{generation}"
      )

    :ok = Sqlite3.close(db)
  end

  defp integer(value), do: %{"type" => "integer", "value" => value}
  defp value(items, id), do: Enum.find(items, &(&1["id"] == id))["value"]
end
