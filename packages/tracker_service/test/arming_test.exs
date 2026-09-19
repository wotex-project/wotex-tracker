defmodule Wotex.Tracker.Service.ArmingTest do
  @moduledoc false

  use ExUnit.Case, async: true
  import Wotex.Tracker.Service.Fixtures
  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.{Arming, Identifier, Store}

  setup do
    c = service()
    {thing, _td} = materialized(c)
    Map.put(c, :thing, thing)
  end

  test "arming commits a private fact and exposes only reviewed state", c do
    {:ok, %{"stream_cursor" => stream}} =
      Service.list(c.service, c.reader, c.scope, "things", %{}, c.now)

    request = %{
      "thing_id" => c.thing,
      "status" => "armed",
      "expected_generation" => "3"
    }

    assert {:error, %{"code" => "forbidden", "outcome" => "not_committed"}} =
             set(c, c.reader, Identifier.uuid(), request, c.now)

    for invalid <- [
          %{},
          Map.put(request, "extra", true),
          %{request | "thing_id" => "thing"},
          %{request | "status" => "unknown"},
          %{request | "expected_generation" => "03"}
        ] do
      assert {:error, %{"code" => "invalid_request"}} =
               set(c, c.admin, Identifier.uuid(), invalid, c.now)
    end

    assert {:error, %{"code" => "not_found"}} =
             set(
               c,
               c.admin,
               Identifier.uuid(),
               %{
                 request
                 | "thing_id" => "urn:uuid:" <> Identifier.uuid()
               },
               c.now
             )

    operation = Identifier.uuid()

    assert {:ok, %{"generation" => "4", "outcome" => "committed", "data" => data} = receipt} =
             set(c, c.admin, operation, request, c.now + 1)

    assert data == %{"thing_id" => c.thing, "status" => "armed"}

    assert {:ok, ^receipt} = set(c, c.admin, operation, request, c.now + 2)

    assert {:ok, %{"generation" => "4", "id" => thing, "value" => armed}} =
             Service.get(c.service, c.reader, c.scope, "arming", c.thing, c.now + 2)

    assert thing == c.thing

    assert armed == %{
             "schema" => "wtr.arming.v1",
             "thing_id" => c.thing,
             "status" => "armed",
             "revision" => "arming-4",
             "changed_at" => c.now + 1,
             "changed_by" => armed["changed_by"]
           }

    assert String.starts_with?(armed["changed_by"], "wtr1_")
    refute inspect(armed) =~ operation
    refute inspect(armed) =~ c.admin

    assert {:ok, %{"items" => [%{"value" => ^armed}]}} =
             Service.list(c.service, c.reader, c.scope, "arming", %{}, c.now + 2)

    assert {:ok, %{"items" => [%{"value" => ^armed}], "cursor" => cursor}} =
             Service.list(c.service, c.reader, c.scope, "arming", %{"limit" => 1}, c.now + 2)

    assert is_binary(cursor)

    assert {:ok, %{"items" => [], "cursor" => nil, "generation" => "4"}} =
             Service.list(
               c.service,
               c.reader,
               c.scope,
               "arming",
               %{"limit" => 1, "cursor" => cursor},
               c.now + 2
             )

    assert {:ok, %{"items" => [%{"value" => ^armed, "deleted" => false}]}} =
             Service.history(c.service, c.reader, c.scope, "arming", c.thing, %{}, c.now + 2)

    assert {:ok, %{"value" => stored}} =
             Store.fetch(c.store, %{
               scope: c.scope,
               kind: "arming",
               id: c.thing,
               generation: nil
             })

    assert {:ok, fact} = Arming.restore_fact(c.thing, stored)
    assert fact.predicate == "asset.armed"
    assert fact.status == "true"
    assert fact.evidence.association_id == c.thing

    assert {:ok, %{"items" => [%{"event" => event}]}} =
             Service.events(c.service, c.reader, c.scope, stream, c.now + 2)

    assert event == %{
             "type" => "arming.changed",
             "data" => %{"thing_id" => c.thing, "status" => "armed"}
           }
  end

  test "disarming is conditional, durable and removed with the enrollment", c do
    assert {:ok, %{"generation" => "4"}} =
             set(c, c.admin, Identifier.uuid(), request(c.thing, "armed", "3"), c.now)

    assert {:error, %{"code" => "conflict"}} =
             set(c, c.admin, Identifier.uuid(), request(c.thing, "disarmed", "3"), c.now + 1)

    assert {:ok, %{"generation" => "5"}} =
             set(c, c.admin, Identifier.uuid(), request(c.thing, "disarmed", "4"), c.now + 2)

    {reopened, _directory} =
      store(directory: c.directory, credentials: c.credentials)

    service = %{c.service | store: reopened}

    assert {:ok, %{"value" => %{"status" => "disarmed", "revision" => "arming-5"}}} =
             Service.get(service, c.reader, c.scope, "arming", c.thing, c.now + 3)

    assert {:ok, %{"generation" => "6"}} =
             Service.unenroll(
               service,
               c.admin,
               c.scope,
               Identifier.uuid(),
               %{"thing_id" => c.thing, "expected_generation" => "5"},
               c.now + 4
             )

    assert {:error, %{"code" => "not_found"}} =
             Service.get(service, c.reader, c.scope, "arming", c.thing, c.now + 4)

    assert {:ok, %{"items" => versions}} =
             Service.history(service, c.reader, c.scope, "arming", c.thing, %{}, c.now + 4)

    assert Enum.map(versions, & &1["deleted"]) == [false, false, true]
  end

  test "corrupt private fact fails the public projection closed", c do
    assert {:ok, %{"generation" => "4"}} =
             set(c, c.admin, Identifier.uuid(), request(c.thing, "armed", "3"), c.now)

    assert {:ok, %{"value" => stored}} =
             Store.fetch(c.store, %{
               scope: c.scope,
               kind: "arming",
               id: c.thing,
               generation: nil
             })

    changed = put_in(stored, ["fact", "predicate"], "asset.other")
    assert {:error, :storage_unavailable} = Arming.project(c.thing, changed)
    assert {:error, :storage_unavailable} = Arming.project("other", stored)
  end

  defp set(c, token, operation, request, now),
    do: Service.set_arming(c.service, token, c.scope, operation, request, now)

  defp request(thing, status, generation),
    do: %{
      "thing_id" => thing,
      "status" => status,
      "expected_generation" => generation
    }
end
