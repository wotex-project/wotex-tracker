defmodule Wotex.Tracker.Service.UnenrollmentTest do
  @moduledoc false

  use ExUnit.Case, async: true
  import Wotex.Tracker.Service.Fixtures
  alias Wotex.Runtime.Context
  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.{Identifier, PropertyObservation, Store}

  setup do
    c = service()
    {thing, _td} = materialized(c)
    Map.put(c, :thing, thing)
  end

  test "unenrollment removes the asset, its state and its rule definitions in one commit", c do
    assert {:ok, %{"generation" => "4"}} = save(c, heartbeat(c.thing, "3"))
    assert {:ok, %{"generation" => "5"}} = save(c, battery(c.thing, "4"))
    assert {:ok, [_, _]} = Store.scheduled_rules(c.store, 10)

    {:ok, %{"stream_cursor" => stream}} =
      Service.list(c.service, c.reader, c.scope, "things", %{}, c.now)

    {:ok, %{"items" => [%{"id" => observation}]}} =
      Service.list(c.service, c.reader, c.scope, "observations", %{}, c.now)

    request = %{"thing_id" => c.thing, "expected_generation" => "5"}

    assert {:error, %{"code" => "forbidden", "outcome" => "not_committed"}} =
             unenroll(c, c.reader, request)

    for invalid <- [
          %{},
          Map.put(request, "extra", true),
          %{request | "thing_id" => "thing"},
          %{request | "expected_generation" => "05"}
        ] do
      assert {:error, %{"code" => "invalid_request"}} = unenroll(c, c.admin, invalid)
    end

    assert {:error, %{"code" => "conflict"}} =
             unenroll(c, c.admin, %{request | "expected_generation" => "4"})

    assert {:error, %{"code" => "conflict"}} =
             unenroll(c, c.admin, %{request | "expected_generation" => "9"})

    assert {:error, %{"code" => "not_found"}} =
             unenroll(c, c.admin, %{request | "thing_id" => "urn:uuid:" <> Identifier.uuid()})

    operation = Identifier.uuid()

    assert {:ok, %{"outcome" => "committed", "generation" => "6", "data" => data} = receipt} =
             Service.unenroll(c.service, c.admin, c.scope, operation, request, c.now)

    assert data == %{
             "thing_id" => c.thing,
             "action" => "unenrolled",
             "policy_ids" => ["low-battery", "sensor-silence"]
           }

    assert {:ok, ^receipt} =
             Service.unenroll(c.service, c.admin, c.scope, operation, request, c.now + 1)

    for resource <- ~w(enrollments things state) do
      assert {:error, %{"code" => "not_found"}} =
               Service.get(c.service, c.reader, c.scope, resource, c.thing, c.now)
    end

    for id <- ~w(low-battery sensor-silence) do
      assert {:error, %{"code" => "not_found"}} =
               Service.get(c.service, c.reader, c.scope, "policies", id, c.now)
    end

    assert {:ok, %{"items" => []}} =
             Service.thing_policies(c.service, c.reader, c.scope, c.thing, c.now)

    assert {:ok, %{"items" => []}} =
             Service.list(c.service, c.reader, c.scope, "enrollments", %{}, c.now)

    assert {:ok, []} = Store.scheduled_rules(c.store, 10)

    assert {:ok, %{"value" => %{"status" => "current"}}} =
             Service.get(c.service, c.reader, c.scope, "rules", "heartbeat:sensor-silence", c.now)

    assert {:ok, %{"items" => versions}} =
             Service.history(c.service, c.reader, c.scope, "enrollments", c.thing, %{}, c.now)

    assert List.last(versions)["deleted"] == true

    assert {:ok, %{"items" => events}} =
             Service.events(c.service, c.reader, c.scope, stream, c.now)

    assert Enum.map(events, & &1["event"]) == [
             %{"type" => "enrollment.changed", "data" => %{"id" => c.thing}},
             %{"type" => "thing.changed", "data" => %{"id" => c.thing}},
             %{
               "type" => "policy.changed",
               "data" => %{"id" => "low-battery", "action" => "deleted"}
             },
             %{
               "type" => "policy.changed",
               "data" => %{"id" => "sensor-silence", "action" => "deleted"}
             }
           ]

    assert {:ok, _raw} = Service.raw_observation(c.service, c.admin, c.scope, observation, c.now)

    assert {:error, %{"code" => "not_found"}} =
             Service.materialize(
               c.service,
               c.admin,
               c.scope,
               Identifier.uuid(),
               %{"thing_id" => c.thing, "expected_generation" => "6"},
               c.now
             )

    assert {:error, %{"code" => "not_found"}} = save(c, heartbeat(c.thing, "6"))

    assert {:error, %{"code" => "not_found"}} =
             unenroll(c, c.admin, %{request | "expected_generation" => "6"})
  end

  test "an open Property observation closes when its Thing is unenrolled", c do
    {:ok, access} = Service.authorize(c.service, c.reader, c.scope, "read", c.now)

    {:ok, initial} =
      PropertyObservation.open(c.service, access, c.thing, "temperature", nil, c.now)

    assert {:ok, %{"generation" => "4"}} =
             unenroll(c, c.admin, %{"thing_id" => c.thing, "expected_generation" => "3"})

    assert {:ok, %{"items" => [], "closed" => true}} =
             PropertyObservation.batch(c.service, access, initial["cursor"], c.now)

    assert {:error, %{"code" => "not_found"}} =
             Service.read_property(
               c.service,
               c.reader,
               c.scope,
               c.thing,
               "temperature",
               Context.new!(request_id: Identifier.uuid(), deadline: 5_000),
               c.now
             )
  end

  test "an asset that was never materialised removes only its enrollment", c do
    {:ok, imported} =
      Service.submit(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        import_request(%{id: "observation-2"}, "3"),
        c.now
      )

    {:ok, %{"data" => %{"thing_id" => second}}} =
      Service.enroll(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        %{
          "observation_id" => imported["data"]["observation_id"],
          "title" => "Second sensor",
          "owner_confirmed" => true,
          "expected_generation" => "4"
        },
        c.now
      )

    {:ok, %{"stream_cursor" => stream}} =
      Service.list(c.service, c.reader, c.scope, "things", %{}, c.now)

    assert {:ok, %{"generation" => "6", "data" => %{"policy_ids" => []}}} =
             unenroll(c, c.admin, %{"thing_id" => second, "expected_generation" => "5"})

    assert {:ok, %{"items" => [%{"event" => event}]}} =
             Service.events(c.service, c.reader, c.scope, stream, c.now)

    assert event == %{"type" => "enrollment.changed", "data" => %{"id" => second}}

    assert {:ok, %{"value" => _}} =
             Service.get(c.service, c.reader, c.scope, "enrollments", c.thing, c.now)
  end

  defp unenroll(c, token, request),
    do: Service.unenroll(c.service, token, c.scope, Identifier.uuid(), request, c.now)

  defp save(c, request),
    do: Service.save_policy(c.service, c.admin, c.scope, Identifier.uuid(), request, c.now)

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
end
