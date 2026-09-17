defmodule Wotex.Tracker.Service.RuleEvaluationTest do
  @moduledoc false
  use ExUnit.Case, async: true
  import Bitwise
  import Wotex.Tracker.Service.Fixtures

  alias Exqlite.Sqlite3
  alias Wotex.Tracker.{BatteryTransition, EvidenceBundle, HeartbeatTransition}
  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.{Identifier, RuleEvaluation, RuleTransition, Store, Update}

  @payload Base.decode16!("0512FC5394C37C0004FFFC040CAC364200CDCBB8334C884F")

  setup do
    c = service()
    {thing, _td} = materialized(c)
    Map.put(c, :thing, thing)
  end

  test "saving definitions evaluates committed Thing evidence in the same commit", c do
    assert {:ok, %{"generation" => "4"}} = save(c, heartbeat(c.thing, "3"), c.now)

    assert {:ok, %{"generation" => "4", "value" => heartbeat}} =
             rule(c, "heartbeat:sensor-silence")

    {:ok, %{"value" => definition}} =
      Service.get(c.service, c.reader, c.scope, "policies", "sensor-silence", c.now)

    assert %{"status" => "current", "rule" => %{"revision" => "4"}} = heartbeat
    assert heartbeat["rule"]["identity"] == definition["policy_identity"]
    assert heartbeat["heartbeat"]["observed_at"] == %{"type" => "integer", "value" => c.now}

    assert {:ok, %{"generation" => "5"}} =
             save(c, battery(c.thing, "4", {3.0, 3.2}), c.now)

    assert {:ok, %{"generation" => "5", "value" => %{"status" => "low"} = low}} =
             rule(c, "battery:low-battery")

    assert low["battery"]["measurement"]["value"] == %{"type" => "number", "value" => 2.977}

    {:ok, %{"stream_cursor" => stream}} =
      Service.list(c.service, c.reader, c.scope, "rules", %{}, c.now)

    assert {:ok, %{"generation" => "6"}} =
             save(c, battery(c.thing, "5", {2.5, 2.8}), c.now + 1)

    assert {:ok, %{"generation" => "6", "value" => %{"status" => "normal"} = normal}} =
             rule(c, "battery:low-battery")

    assert normal["rule"]["revision"] == "6"

    assert {:ok,
            %{
              "items" => [
                %{"event" => %{"type" => "policy.changed"}},
                %{"generation" => "6", "event" => event_envelope}
              ]
            }} =
             Service.events(c.service, c.reader, c.scope, stream, c.now + 1)

    assert %{"type" => "tracker.event", "data" => %{"kind" => "battery.recomputed"} = event} =
             event_envelope

    assert {:ok, intent} = Store.rule_event(c.store, c.scope, event["id"])
    assert intent["mode"] == "live"
    assert intent["physical_action_dispatch"] == "separate_authorization_required"
  end

  test "materialising a later observation evaluates definitions atomically", c do
    assert {:ok, _} = save(c, heartbeat(c.thing, "3"), c.now)
    assert {:ok, _} = save(c, battery(c.thing, "4", {2.5, 2.8}), c.now)
    assert {:ok, %{"value" => %{"status" => "normal"}}} = rule(c, "battery:low-battery")

    later = c.now + 60_000

    {:ok, imported} =
      Service.submit(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        import_request(
          %{id: "observation-2", observed_at: later, payload: battery_payload(2_400)},
          "5"
        ),
        later
      )

    assert {:ok, %{"generation" => "7"}} =
             Service.associate(
               c.service,
               c.admin,
               c.scope,
               Identifier.uuid(),
               %{
                 "thing_id" => c.thing,
                 "observation_id" => imported["data"]["observation_id"],
                 "owner_confirmed" => true,
                 "expected_generation" => "6"
               },
               later
             )

    assert {:ok, %{"value" => %{"status" => "normal"}}} = rule(c, "battery:low-battery")

    operation = Identifier.uuid()
    request = %{"thing_id" => c.thing, "expected_generation" => "7"}

    assert {:ok, %{"generation" => "8"} = receipt} =
             Service.materialize(c.service, c.admin, c.scope, operation, request, later)

    assert {:ok, %{"generation" => "8", "value" => battery}} = rule(c, "battery:low-battery")
    assert battery["status"] == "low"
    assert battery["battery"]["measurement"]["value"] == %{"type" => "number", "value" => 2.4}

    assert {:ok, %{"generation" => "8", "value" => heartbeat}} =
             rule(c, "heartbeat:sensor-silence")

    assert heartbeat["status"] == "current"
    assert heartbeat["heartbeat"]["observed_at"] == %{"type" => "integer", "value" => later}

    assert {:ok, %{"items" => versions}} =
             Service.history(
               c.service,
               c.reader,
               c.scope,
               "rules",
               "battery:low-battery",
               %{},
               later
             )

    assert Enum.map(versions, & &1["generation"]) == ["5", "8"]

    assert {:ok, ^receipt} =
             Service.materialize(c.service, c.admin, c.scope, operation, request, later + 1)

    assert {:ok, %{"items" => ^versions}} =
             Service.history(
               c.service,
               c.reader,
               c.scope,
               "rules",
               "battery:low-battery",
               %{},
               later + 1
             )
  end

  test "deleted definitions stop scheduling and a reused ID keeps its Thing", c do
    assert {:ok, _} = save(c, heartbeat(c.thing, "3"), c.now)
    assert {:ok, [%{"rule_id" => "sensor-silence"}]} = Store.scheduled_rules(c.store, 10)

    assert {:ok, %{"generation" => "5"}} =
             Service.delete_policy(
               c.service,
               c.admin,
               c.scope,
               Identifier.uuid(),
               %{"id" => "sensor-silence", "expected_generation" => "4"},
               c.now
             )

    assert {:ok, []} = Store.scheduled_rules(c.store, 10)

    assert {:ok, %{"retired" => true}} =
             Store.rule_state(c.store, c.scope, "heartbeat", "sensor-silence")

    assert {:ok, %{"value" => %{"status" => "current"}}} = rule(c, "heartbeat:sensor-silence")

    other = "urn:uuid:" <> Identifier.uuid()
    assert {:error, %{"code" => "not_found"}} = save(c, heartbeat(other, "5"), c.now)

    changed = put_in(heartbeat(c.thing, "5"), ["parameters", "maximum_silence_ms"], 60_000)
    assert {:ok, %{"generation" => "6"}} = save(c, changed, c.now + 1)

    assert {:ok, %{"retired" => false}} =
             Store.rule_state(c.store, c.scope, "heartbeat", "sensor-silence")

    assert {:ok, [%{"rule_id" => "sensor-silence"}]} = Store.scheduled_rules(c.store, 10)

    assert {:ok, %{"value" => definition}} =
             Service.get(c.service, c.reader, c.scope, "policies", "sensor-silence", c.now)

    assert definition["created_at"] == c.now + 1

    assert {:ok, %{"value" => %{"rule" => %{"revision" => "6"}}}} =
             rule(c, "heartbeat:sensor-silence")
  end

  test "a definition cannot be recreated for another Thing after deletion", c do
    assert {:ok, _} = save(c, heartbeat(c.thing, "3"), c.now)

    assert {:ok, %{"generation" => "5"}} =
             Service.delete_policy(
               c.service,
               c.admin,
               c.scope,
               Identifier.uuid(),
               %{"id" => "sensor-silence", "expected_generation" => "4"},
               c.now
             )

    second = second_thing(c, "5")
    assert {:error, %{"code" => "conflict"}} = save(c, heartbeat(second, "8"), c.now)

    assert {:error, %{"code" => "conflict"}} =
             save(c, heartbeat(c.thing, "99"), c.now)
  end

  test "a staged rule transition with a stale prior state commits nothing", c do
    capture = observation(%{id: "capture", observed_at: c.now})

    {:ok, policy} =
      HeartbeatTransition.new(%{
        id: "stale",
        revision: "1",
        maximum_silence_ms: 10,
        future_skew_ms: 0
      })

    {:ok, baseline} = HeartbeatTransition.evaluate(nil, capture, policy, :live, c.now)
    {:ok, first} = RuleTransition.new(c.scope, nil, baseline)
    {:ok, access} = Service.authorize(c.service, c.admin, c.scope, "admin", c.now)

    update = fn transition, operation ->
      Update.new(%{
        principal: access.principal,
        scope: c.scope,
        authority: access,
        operation_id: operation,
        expected_generation: "4",
        now: c.now,
        request: %{"operation" => "stage", "id" => operation},
        observation: nil,
        publication: nil,
        records: [%{kind: "policies", id: "stale", value: %{"marker" => operation}}],
        events: [],
        rules: [transition]
      })
    end

    {:ok, committed} = Store.commit_rule(c.store, first)
    assert committed["generation"] == "4"

    {:ok, stale} = update.(first, Identifier.uuid())
    assert {:error, :conflict} = Store.mutate(c.store, stale)

    assert {:error, :invalid_update} =
             update.(%{first | scope: "other"}, Identifier.uuid())

    assert {:error, :invalid_update} =
             Update.new(%{
               principal: access.principal,
               scope: c.scope,
               authority: access,
               operation_id: Identifier.uuid(),
               expected_generation: "4",
               now: c.now,
               request: %{},
               observation: nil,
               publication: nil,
               records: [],
               events: [],
               rules: [first, first]
             })
  end

  test "damaged Thing evidence fails a definition save without committing", c do
    [[original]] =
      sql(c, "SELECT document FROM records WHERE kind='evidence' AND id=?", [c.thing])

    [[observation]] = sql(c, "SELECT id FROM observations")

    for {document, code} <- [
          {~s({"claims":1,"public":{}}), "storage_unavailable"},
          {~s({"claims":[{"id":"bad"}],"public":{}}), "storage_unavailable"},
          {~s({"claims":[],"public":{}}), "storage_unavailable"}
        ] do
      sql(c, "UPDATE records SET document=? WHERE kind='evidence' AND id=?", [document, c.thing])
      assert {:error, %{"code" => ^code}} = save(c, heartbeat(c.thing, "3"), c.now)
    end

    sql(c, "UPDATE records SET document=? WHERE kind='evidence' AND id=?", [original, c.thing])
    sql(c, "UPDATE observations SET id='elsewhere' WHERE id=?", [observation])
    assert {:error, %{"code" => "not_found"}} = save(c, heartbeat(c.thing, "3"), c.now)
    sql(c, "UPDATE observations SET id=? WHERE id='elsewhere'", [observation])
    assert {:ok, %{"generation" => "4"}} = save(c, heartbeat(c.thing, "3"), c.now)
  end

  test "damaged rule state or definitions block evaluation", c do
    assert {:ok, %{"generation" => "4"}} = save(c, heartbeat(c.thing, "3"), c.now)
    [[state]] = sql(c, "SELECT document FROM rule_states")
    sql(c, "UPDATE rule_states SET document='{}'")
    edit = put_in(heartbeat(c.thing, "4"), ["parameters", "future_skew_ms"], 0)
    assert {:error, %{"code" => "storage_unavailable"}} = save(c, edit, c.now)
    sql(c, "UPDATE rule_states SET document=?", [state])

    sql(
      c,
      "UPDATE records SET document=json_set(document,'$.public.revision','0') WHERE kind='policies'"
    )

    assert {:error, %{"code" => "storage_unavailable"}} =
             Service.materialize(
               c.service,
               c.admin,
               c.scope,
               Identifier.uuid(),
               %{"thing_id" => c.thing, "expected_generation" => "4"},
               c.now
             )
  end

  test "missing measurements leave a rule unchanged and reused evidence IDs conflict", c do
    assert {:ok, _} = save(c, heartbeat(c.thing, "3"), c.now)
    {:ok, definitions} = definitions(c, "4")
    [%{kind: "heartbeat"} = heartbeat_definition] = definitions

    {:ok, battery_policy} =
      BatteryTransition.new(%{
        id: "low-battery",
        revision: "5",
        measurement_kind: "batteryVoltage",
        unit: "V",
        low_threshold: 2.5,
        clear_threshold: 2.8,
        maximum_age_ms: 3_600_000,
        future_skew_ms: 0,
        accept_suspect: false
      })

    battery_definition = %{kind: "battery", thing_id: c.thing, policy: battery_policy}
    changed = observation(%{observed_at: c.now + 1})
    {:ok, empty} = EvidenceBundle.new([changed], [])

    assert {:ok, []} =
             RuleEvaluation.transitions(
               c.service,
               c.scope,
               [battery_definition],
               changed,
               empty,
               c.now + 1
             )

    assert {:error, :conflict} =
             RuleEvaluation.transitions(
               c.service,
               c.scope,
               [heartbeat_definition],
               changed,
               empty,
               c.now + 1
             )
  end

  test "alerts of defined rules are bound to their Thing and paged per Thing", c do
    assert {:ok, _} = save(c, battery(c.thing, "3", {3.0, 3.2}), c.now)
    assert {:ok, _} = save(c, battery(c.thing, "4", {2.5, 2.8}), c.now + 1)
    assert {:ok, %{"generation" => "6"}} = save(c, battery(c.thing, "5", {3.0, 3.2}), c.now + 2)
    second = second_thing(c, "6")

    other =
      c.thing
      |> battery("9", {2.5, 2.8})
      |> Map.merge(%{"id" => "other-battery", "thing_id" => second})

    assert {:ok, %{"generation" => "10"}} = save(c, other, c.now + 3)
    changed = other |> battery_thresholds({3.0, 3.2}) |> Map.put("expected_generation", "10")
    assert {:ok, %{"generation" => "11"}} = save(c, changed, c.now + 4)

    {:ok, %{"items" => all}} = Service.list(c.service, c.reader, c.scope, "alerts", %{}, c.now)
    ours = Enum.filter(all, &(&1["value"]["thing_id"] == c.thing))
    theirs = Enum.filter(all, &(&1["value"]["thing_id"] == second))
    assert length(ours) >= 2 and theirs != []
    assert length(ours) + length(theirs) == length(all)

    assert Enum.all?(
             ours,
             &(&1["value"]["rule"] == %{"kind" => "battery", "id" => "low-battery"})
           )

    assert collect(c, c.thing, %{"limit" => 1}, []) == ours
    assert {:ok, %{"items" => ^theirs, "cursor" => nil}} = thing_alerts(c, second, %{})

    {:ok, %{"cursor" => cursor}} = thing_alerts(c, c.thing, %{"limit" => 1})

    {:ok, %{"cursor" => plain}} =
      Service.list(c.service, c.reader, c.scope, "alerts", %{"limit" => 1}, c.now)

    for {thing, params} <- [
          {second, %{"cursor" => cursor}},
          {c.thing, %{"cursor" => cursor, "limit" => 2}},
          {c.thing, %{"cursor" => plain}},
          {"", %{"cursor" => cursor}}
        ] do
      assert {:error, %{"code" => "invalid_cursor"}} = thing_alerts(c, thing, params)
    end

    assert {:ok, %{"items" => [], "cursor" => nil}} = thing_alerts(c, "urn:uuid:unknown", %{})
    assert {:error, %{"code" => "invalid_request"}} = thing_alerts(c, c.thing, %{"limit" => 0})
    assert {:error, %{"code" => "invalid_request"}} = thing_alerts(c, c.thing, %{"other" => 1})
    assert {:error, %{"code" => "invalid_request"}} = thing_alerts(c, c.thing, nil)
    assert {:error, %{"code" => "invalid_query"}} = thing_alerts(c, "", %{})

    assert {:error, %{"code" => "unauthorized"}} =
             Service.thing_alerts(c.service, "invalid", c.scope, c.thing, %{}, c.now)
  end

  defp collect(c, thing, params, acc) do
    {:ok, %{"items" => items, "cursor" => cursor}} = thing_alerts(c, thing, params)

    if cursor,
      do: collect(c, thing, %{"cursor" => cursor}, acc ++ items),
      else: acc ++ items
  end

  defp thing_alerts(c, thing, params),
    do: Service.thing_alerts(c.service, c.reader, c.scope, thing, params, c.now)

  defp battery_thresholds(request, {low, clear}),
    do:
      request
      |> put_in(["parameters", "low_threshold"], low)
      |> put_in(["parameters", "clear_threshold"], clear)

  defp definitions(c, generation) do
    {:ok, access} = Service.authorize(c.service, c.admin, c.scope, "admin", c.now)
    RuleEvaluation.definitions(c.service, access, "admin", c.thing, generation, c.now)
  end

  # A second connection models on-disk damage below the transactional store API.
  defp sql(c, statement, arguments \\ []) do
    {:ok, db} = Sqlite3.open(Path.join(c.directory, "tracker.db"))

    try do
      {:ok, prepared} = Sqlite3.prepare(db, statement)
      :ok = Sqlite3.bind(prepared, arguments)
      {:ok, rows} = Sqlite3.fetch_all(db, prepared)
      :ok = Sqlite3.release(db, prepared)
      rows
    after
      Sqlite3.close(db)
    end
  end

  defp rule(c, id), do: Service.get(c.service, c.reader, c.scope, "rules", id, c.now)

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

  defp battery(thing, generation, {low, clear}),
    do: %{
      "id" => "low-battery",
      "kind" => "battery",
      "thing_id" => thing,
      "parameters" => %{
        "measurement_kind" => "batteryVoltage",
        "unit" => "V",
        "low_threshold" => low,
        "clear_threshold" => clear,
        "maximum_age_ms" => 3_600_000,
        "future_skew_ms" => 1_000,
        "accept_suspect" => false
      },
      "expected_generation" => generation
    }

  # RAWv2 stores battery millivolts above 1.6 V in the upper 11 power bits.
  defp battery_payload(millivolts) do
    <<head::binary-size(13), power::16, rest::binary>> = @payload
    {:bytes, <<head::binary, (millivolts - 1_600) <<< 5 ||| (power &&& 31)::16, rest::binary>>}
  end

  defp second_thing(c, generation) do
    base = String.to_integer(generation)

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
