defmodule Wotex.Tracker.Service.TripHistoryTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import Wotex.Tracker.Service.Fixtures

  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.{Alert, Identifier, Store, Update}

  setup do
    context = service()
    thing = "urn:uuid:" <> Identifier.uuid()
    other = "urn:uuid:" <> Identifier.uuid()

    put_alert(context, 1, thing, "trip.started")
    put_alert(context, 2, thing, "battery.low")
    put_alert(context, 3, other, "trip.started")
    put_alert(context, 4, thing, "trip.stopped")
    put_alert(context, 5, thing, "trip.interrupted")

    context
    |> Map.put(:thing, thing)
    |> Map.put(:other, other)
  end

  test "trip pages exclude unrelated alerts and bind their immutable snapshot", c do
    assert {:ok, %{"generation" => "5", "items" => [first], "cursor" => cursor}} =
             trips(c, c.thing, %{"limit" => 1})

    assert first["value"]["event"]["kind"] == "trip.interrupted"
    refute get_in(first, ["value", "event", "from_observation_id"])

    put_alert(c, 6, c.thing, "trip.started")

    assert collect(c, c.thing, %{"cursor" => cursor}, [])
           |> Enum.map(&get_in(&1, ["value", "event", "kind"])) == [
             "trip.stopped",
             "trip.started"
           ]

    assert {:ok, %{"generation" => "6", "items" => [fresh]}} =
             trips(c, c.thing, %{"limit" => 1})

    assert fresh["value"]["event"]["kind"] == "trip.started"
  end

  test "trip cursors are caller, Thing, endpoint and page-size specific", c do
    assert {:ok, %{"cursor" => cursor}} = trips(c, c.thing, %{"limit" => 1})

    assert {:ok, %{"cursor" => alert_cursor}} =
             Service.thing_alerts(c.service, c.reader, c.scope, c.thing, %{"limit" => 1}, c.now)

    for {thing, params} <- [
          {c.other, %{"cursor" => cursor}},
          {c.thing, %{"cursor" => cursor, "limit" => 2}},
          {c.thing, %{"cursor" => alert_cursor}}
        ] do
      assert {:error, %{"code" => "invalid_cursor"}} = trips(c, thing, params)
    end

    assert {:error, %{"code" => "unauthorized"}} =
             Service.thing_trips(c.service, "invalid", c.scope, c.thing, %{}, c.now)
  end

  test "trip windows are half-open and their bounds are cursor-bound", c do
    window = %{"from_at" => c.now + 4, "to_at" => c.now + 6, "limit" => 1}

    assert {:ok, %{"items" => [interrupted], "cursor" => cursor}} =
             trips(c, c.thing, window)

    assert interrupted["value"]["event"]["kind"] == "trip.interrupted"

    assert {:ok, %{"items" => [stopped]}} = trips(c, c.thing, %{"cursor" => cursor})
    assert stopped["value"]["event"]["kind"] == "trip.stopped"

    for params <- [
          %{"from_at" => c.now + 4},
          %{"to_at" => c.now + 6},
          %{"from_at" => c.now + 6, "to_at" => c.now + 6},
          %{"from_at" => c.now + 4, "to_at" => c.now + 6, "cursor" => cursor}
        ] do
      assert {:error, %{"code" => "invalid_request"}} = trips(c, c.thing, params)
    end
  end

  test "trip query admission is closed and unknown Things have no events", c do
    unknown = "urn:uuid:" <> Identifier.uuid()
    assert {:ok, %{"items" => [], "cursor" => nil}} = trips(c, unknown, %{})
    assert {:error, %{"code" => "invalid_request"}} = trips(c, c.thing, %{"limit" => 0})
    assert {:error, %{"code" => "invalid_request"}} = trips(c, c.thing, %{"other" => 1})
    assert {:error, %{"code" => "invalid_request"}} = trips(c, c.thing, nil)
    assert {:error, %{"code" => "invalid_query"}} = trips(c, "", %{})
  end

  defp collect(c, thing, params, acc) do
    {:ok, %{"items" => items, "cursor" => cursor}} = trips(c, thing, params)

    if cursor,
      do: collect(c, thing, %{"cursor" => cursor}, acc ++ items),
      else: acc ++ items
  end

  defp trips(c, thing, params),
    do: Service.thing_trips(c.service, c.reader, c.scope, thing, params, c.now)

  defp put_alert(c, generation, thing, kind) do
    {:ok, access} = Service.authorize(c.service, c.admin, c.scope, "admin", c.now)
    event_id = "trip-event-#{generation}"
    alert_id = Alert.id(generation, event_id)

    public = %{
      "schema" => "wtr.alert.v1",
      "id" => alert_id,
      "event_id" => event_id,
      "event" => %{
        "schema" => "wtr.trip-event.v1",
        "id" => event_id,
        "kind" => kind,
        "rule_id" => "movement",
        "trip_id" => "trip-one",
        "effective_at" => c.now + generation
      },
      "rule" => %{
        "kind" => if(kind == "battery.low", do: "battery", else: "motion"),
        "id" => "movement"
      },
      "thing_id" => thing,
      "mode" => "live",
      "physical_action_dispatch" => "separate_authorization_required",
      "created_at" => c.now + generation,
      "generation" => Integer.to_string(generation),
      "acknowledgement" => nil
    }

    {:ok, update} =
      Update.new(%{
        principal: access.principal,
        scope: c.scope,
        authority: access,
        operation_id: Identifier.uuid(),
        expected_generation: Integer.to_string(generation - 1),
        request: %{"operation" => "trip-history-fixture", "generation" => generation},
        now: c.now + generation,
        observation: nil,
        records: [
          %{
            kind: "alerts",
            id: alert_id,
            value: %{"public" => public, "from_observation_id" => "private-observation"}
          }
        ],
        events: [],
        publication: nil
      })

    assert {:ok, %{"generation" => result}} = Store.mutate(c.store, update)
    assert result == Integer.to_string(generation)
  end
end
