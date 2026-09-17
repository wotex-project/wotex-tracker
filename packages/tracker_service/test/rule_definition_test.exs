defmodule Wotex.Tracker.Service.RuleDefinitionTest do
  @moduledoc false
  use ExUnit.Case, async: true
  import Wotex.Tracker.Service.Fixtures

  alias Exqlite.Sqlite3
  alias Wotex.Tracker.{BatteryTransition, HeartbeatTransition}
  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.{Codec, Identifier}

  setup do
    c = service()
    {thing, _td} = materialized(c)
    Map.put(c, :thing, thing)
  end

  test "administrators version heartbeat and battery definitions for an enrolled Thing", c do
    {:ok, %{"stream_cursor" => stream}} =
      Service.list(c.service, c.reader, c.scope, "policies", %{}, c.now)

    operation = Identifier.uuid()
    request = heartbeat(c.thing, "3")

    assert {:ok, %{"generation" => "4", "data" => data} = receipt} =
             Service.save_policy(c.service, c.admin, c.scope, operation, request, c.now)

    assert data == %{"policy_id" => "sensor-silence", "action" => "saved"}

    assert {:ok, ^receipt} =
             Service.save_policy(c.service, c.admin, c.scope, operation, request, c.now)

    {:ok, policy} =
      HeartbeatTransition.new(%{
        id: "sensor-silence",
        revision: "4",
        maximum_silence_ms: 600_000,
        future_skew_ms: 1_000
      })

    assert {:ok, %{"generation" => "4", "value" => value}} =
             Service.get(c.service, c.reader, c.scope, "policies", "sensor-silence", c.now)

    assert value == %{
             "schema" => "wtr.rule-definition.v1",
             "id" => "sensor-silence",
             "kind" => "heartbeat",
             "thing_id" => c.thing,
             "revision" => "4",
             "policy_identity" => policy.identity,
             "parameters" => %{"maximum_silence_ms" => 600_000, "future_skew_ms" => 1_000},
             "created_at" => c.now,
             "updated_at" => c.now
           }

    assert {:ok, %{"generation" => "5"}} =
             save(c, battery(c.thing, "4"), c.now + 1)

    changed = put_in(request, ["parameters", "maximum_silence_ms"], 900_000)

    assert {:ok, %{"generation" => "6"}} =
             save(c, Map.put(changed, "expected_generation", "5"), c.now + 2)

    assert {:ok, %{"items" => items, "generation" => "6"}} =
             Service.list(c.service, c.reader, c.scope, "policies", %{}, c.now)

    assert Enum.map(items, &{&1["id"], &1["value"]["kind"], &1["value"]["revision"]}) == [
             {"low-battery", "battery", "5"},
             {"sensor-silence", "heartbeat", "6"}
           ]

    edited = Enum.find(items, &(&1["id"] == "sensor-silence"))["value"]
    assert edited["created_at"] == c.now
    assert edited["updated_at"] == c.now + 2
    refute Map.has_key?(edited, "actor")

    {:ok, battery_policy} =
      BatteryTransition.new(%{
        id: "low-battery",
        revision: "5",
        measurement_kind: "batteryVoltage",
        unit: "V",
        low_threshold: 2.5,
        clear_threshold: 2.8,
        maximum_age_ms: 3_600_000,
        future_skew_ms: 1_000,
        accept_suspect: false
      })

    assert Enum.find(items, &(&1["id"] == "low-battery"))["value"]["policy_identity"] ==
             battery_policy.identity

    assert {:ok, %{"generation" => "7", "data" => %{"action" => "deleted"}}} =
             Service.delete_policy(
               c.service,
               c.admin,
               c.scope,
               Identifier.uuid(),
               %{"id" => "sensor-silence", "expected_generation" => "6"},
               c.now + 3
             )

    assert {:error, %{"code" => "not_found"}} =
             Service.get(c.service, c.reader, c.scope, "policies", "sensor-silence", c.now)

    assert {:ok, %{"items" => [first, _second], "cursor" => cursor}} =
             Service.history(
               c.service,
               c.reader,
               c.scope,
               "policies",
               "sensor-silence",
               %{"limit" => 2},
               c.now
             )

    assert first["value"]["revision"] == "4"

    assert {:ok, %{"items" => [%{"deleted" => true, "value" => nil}]}} =
             Service.history(
               c.service,
               c.reader,
               c.scope,
               "policies",
               "sensor-silence",
               %{"cursor" => cursor},
               c.now
             )

    assert {:ok, %{"items" => events}} =
             Service.events(c.service, c.reader, c.scope, stream, c.now)

    assert Enum.map(events, &{&1["event"]["type"], &1["event"]["data"]["action"]}) == [
             {"policy.changed", "saved"},
             {"policy.changed", "saved"},
             {"policy.changed", "saved"},
             {"tracker.event", nil},
             {"policy.changed", "deleted"}
           ]
  end

  test "definition admission, authority and Thing support fail closed", c do
    assert {:error, %{"code" => "forbidden", "outcome" => "not_committed"}} =
             Service.save_policy(
               c.service,
               c.reader,
               c.scope,
               Identifier.uuid(),
               heartbeat(c.thing, "3"),
               c.now
             )

    for invalid <- [
          Map.put(heartbeat(c.thing, "3"), "id", "Sensor:silence"),
          Map.put(heartbeat(c.thing, "3"), "kind", "motion"),
          Map.put(heartbeat(c.thing, "3"), "armed", true),
          Map.put(heartbeat(c.thing, "3"), "thing_id", "sensor"),
          Map.put(heartbeat(c.thing, "3"), "expected_generation", 3),
          put_in(heartbeat(c.thing, "3"), ["parameters", "maximum_silence_ms"], 604_800_001),
          put_in(heartbeat(c.thing, "3"), ["parameters", "extra"], 1),
          put_in(battery(c.thing, "3"), ["parameters", "clear_threshold"], 2.5),
          put_in(battery(c.thing, "3"), ["parameters", "accept_suspect"], "no")
        ] do
      assert {:error, %{"code" => "invalid_request"}} = save(c, invalid, c.now)
    end

    missing = "urn:uuid:" <> Identifier.uuid()
    assert {:error, %{"code" => "not_found"}} = save(c, heartbeat(missing, "3"), c.now)

    for {kind, unit} <- [{"humidity", "V"}, {"batteryPercentage", "%"}] do
      unsupported =
        c.thing
        |> battery("3")
        |> put_in(["parameters", "measurement_kind"], kind)
        |> put_in(["parameters", "unit"], unit)

      assert {:error, %{"code" => "unsupported"}} = save(c, unsupported, c.now)
    end

    assert {:error, %{"code" => "not_found"}} = save(c, heartbeat(c.thing, "2"), c.now)
    assert {:ok, %{"generation" => "4"}} = save(c, heartbeat(c.thing, "3"), c.now)
    assert {:error, %{"code" => "conflict"}} = save(c, battery(c.thing, "3"), c.now)

    assert {:error, %{"code" => "conflict"}} =
             save(c, Map.put(battery(c.thing, "4"), "id", "sensor-silence"), c.now)

    second = second_thing(c, "4")

    assert {:error, %{"code" => "conflict"}} =
             save(c, heartbeat(second, "7"), c.now)

    assert {:error, %{"code" => "not_found"}} =
             Service.delete_policy(
               c.service,
               c.admin,
               c.scope,
               Identifier.uuid(),
               %{"id" => "absent", "expected_generation" => "7"},
               c.now
             )

    assert {:error, %{"code" => "invalid_request"}} =
             Service.delete_policy(
               c.service,
               c.admin,
               c.scope,
               Identifier.uuid(),
               %{"id" => "sensor:silence", "expected_generation" => "7"},
               c.now
             )
  end

  test "readers list only the live definitions bound to one Thing", c do
    assert {:ok, %{"generation" => "3", "items" => []}} =
             Service.thing_policies(c.service, c.reader, c.scope, c.thing, c.now)

    assert {:ok, _} = save(c, heartbeat(c.thing, "3"), c.now)
    assert {:ok, _} = save(c, battery(c.thing, "4"), c.now)
    second = second_thing(c, "5")

    other =
      c.thing |> heartbeat("8") |> Map.merge(%{"id" => "other-silence", "thing_id" => second})

    assert {:ok, %{"generation" => "9"}} = save(c, other, c.now)

    assert {:ok, %{"generation" => "9", "items" => items}} =
             Service.thing_policies(c.service, c.reader, c.scope, c.thing, c.now)

    assert Enum.map(items, &{&1["id"], &1["value"]["kind"], &1["value"]["thing_id"]}) == [
             {"low-battery", "battery", c.thing},
             {"sensor-silence", "heartbeat", c.thing}
           ]

    refute Enum.any?(items, &Map.has_key?(&1["value"], "actor"))

    assert {:ok, %{"generation" => "10"}} =
             Service.delete_policy(
               c.service,
               c.admin,
               c.scope,
               Identifier.uuid(),
               %{"id" => "low-battery", "expected_generation" => "9"},
               c.now
             )

    assert {:ok, %{"items" => [%{"id" => "sensor-silence"}]}} =
             Service.thing_policies(c.service, c.reader, c.scope, c.thing, c.now)

    assert {:ok, %{"items" => []}} =
             Service.thing_policies(c.service, c.reader, c.scope, "urn:uuid:unknown", c.now)

    assert {:error, %{"code" => "unauthorized"}} =
             Service.thing_policies(c.service, "invalid", c.scope, c.thing, c.now)

    assert {:error, %{"code" => "invalid_query"}} =
             Service.thing_policies(c.service, c.reader, c.scope, "", c.now)
  end

  test "one Thing admits at most eight definitions while edits remain possible", c do
    for index <- 1..8 do
      request =
        c.thing
        |> heartbeat(Integer.to_string(index + 2))
        |> Map.put("id", "silence-#{index}")

      assert {:ok, %{"generation" => generation}} = save(c, request, c.now)
      assert generation == Integer.to_string(index + 3)
    end

    ninth = c.thing |> heartbeat("11") |> Map.put("id", "silence-9")
    assert {:error, %{"code" => "capacity_exceeded"}} = save(c, ninth, c.now)

    edit =
      c.thing
      |> heartbeat("11")
      |> Map.put("id", "silence-8")
      |> put_in(["parameters", "future_skew_ms"], 0)

    assert {:ok, %{"generation" => "12"}} = save(c, edit, c.now)

    assert {:ok, %{"generation" => "13"}} =
             Service.delete_policy(
               c.service,
               c.admin,
               c.scope,
               Identifier.uuid(),
               %{"id" => "silence-1", "expected_generation" => "12"},
               c.now
             )

    assert {:ok, %{"generation" => "14"}} =
             save(c, Map.put(ninth, "expected_generation", "13"), c.now)
  end

  test "future snapshots and damaged stored definitions are never overwritten", c do
    assert {:error, %{"code" => "conflict"}} = save(c, heartbeat(c.thing, "99"), c.now)
    assert {:ok, %{"generation" => "4"}} = save(c, heartbeat(c.thing, "3"), c.now)

    {:ok, db} = Sqlite3.open(Path.join(c.directory, "tracker.db"))
    :ok = Sqlite3.execute(db, "UPDATE records SET document='{}' WHERE kind='policies'")
    :ok = Sqlite3.close(db)

    edit = put_in(heartbeat(c.thing, "4"), ["parameters", "future_skew_ms"], 0)
    assert {:error, %{"code" => "storage_unavailable"}} = save(c, edit, c.now)

    assert {:error, %{"code" => "storage_unavailable"}} =
             Service.delete_policy(
               c.service,
               c.admin,
               c.scope,
               Identifier.uuid(),
               %{"id" => "sensor-silence", "expected_generation" => "4"},
               c.now
             )
  end

  defp save(c, request, now),
    do: Service.save_policy(c.service, c.admin, c.scope, Identifier.uuid(), request, now)

  defp heartbeat(thing, generation),
    do: %{
      "id" => "sensor-silence",
      "kind" => "heartbeat",
      "thing_id" => thing,
      "parameters" => %{"maximum_silence_ms" => 600_000, "future_skew_ms" => 1_000},
      "expected_generation" => generation
    }

  defp battery(thing, generation),
    do: %{
      "id" => "low-battery",
      "kind" => "battery",
      "thing_id" => thing,
      "parameters" => %{
        "measurement_kind" => "batteryVoltage",
        "unit" => "V",
        "low_threshold" => 2.5,
        "clear_threshold" => 2.8,
        "maximum_age_ms" => 3_600_000,
        "future_skew_ms" => 1_000,
        "accept_suspect" => false
      },
      "expected_generation" => generation
    }

  defp second_thing(c, generation) do
    {:ok, base} = Codec.generation(generation)

    {:ok, imported} =
      Service.submit(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        import_request(%{id: "observation-2"}, generation),
        c.now
      )

    {:ok, enrolled} =
      Service.enroll(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        %{
          "observation_id" => imported["data"]["observation_id"],
          "title" => "Second sensor",
          "owner_confirmed" => true,
          "expected_generation" => Integer.to_string(base + 1)
        },
        c.now
      )

    thing = enrolled["data"]["thing_id"]

    {:ok, _} =
      Service.materialize(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        %{"thing_id" => thing, "expected_generation" => Integer.to_string(base + 2)},
        c.now
      )

    thing
  end
end
