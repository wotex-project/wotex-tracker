defmodule Wotex.Tracker.AssociationTest do
  use ExUnit.Case, async: true
  import Wotex.Tracker.Service.Fixtures
  alias Wotex.Runtime.Context
  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.{Identifier, Store}

  test "a later explicitly confirmed observation updates the same Thing with preserved history" do
    c = service()
    {thing, _} = materialized(c)
    <<5, _::16, rest::binary>> = elem(observation().payload, 1)

    {:ok, imported} =
      Service.submit(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        import_request(
          %{
            id: "second",
            observed_at: c.now + 1,
            payload: {:bytes, <<5, 6000::16, rest::binary>>}
          },
          "3"
        ),
        c.now
      )

    request = %{
      "thing_id" => thing,
      "observation_id" => imported["data"]["observation_id"],
      "owner_confirmed" => true,
      "expected_generation" => "4"
    }

    operation = Identifier.uuid()
    assert {:ok, receipt} = associate(c, operation, request)
    assert receipt["generation"] == "5"
    assert receipt["data"]["thing_id"] == thing
    assert {:ok, ^receipt} = associate(c, operation, request)
    assert {:ok, %{"value" => 24.3}} = read(c, thing)

    assert {:ok, _} =
             Service.materialize(
               c.service,
               c.admin,
               c.scope,
               Identifier.uuid(),
               %{"thing_id" => thing, "expected_generation" => "5"},
               c.now
             )

    assert {:ok, %{"value" => 30.0, "generation" => "6"}} = read(c, thing)

    assert {:ok, history} =
             Service.history(c.service, c.reader, c.scope, "enrollments", thing, %{}, c.now)

    assert Enum.map(history["items"], & &1["generation"]) == ["2", "5"]

    assert {:ok, states} =
             Service.history(c.service, c.reader, c.scope, "state", thing, %{}, c.now)

    assert Enum.map(states["items"], & &1["generation"]) == ["3", "6"]

    assert {:ok, %{"items" => [_]}} =
             Service.list(c.service, c.reader, c.scope, "things", %{}, c.now)

    assert {:ok, %{"value" => old}} =
             Store.fetch(c.store, %{
               scope: c.scope,
               kind: "enrollments",
               id: thing,
               generation: "2"
             })

    assert {:ok, %{"value" => new}} =
             Store.fetch(c.store, %{
               scope: c.scope,
               kind: "enrollments",
               id: thing,
               generation: "6"
             })

    refute old["association_id"] == new["association_id"]
    assert new["identity_revision"] == operation
    assert new["actor"] == "owner"
  end

  test "association requires confirmation, enrollment authority and an existing resolved observation" do
    c = service()
    {thing, _} = materialized(c)
    {:ok, observations} = Service.list(c.service, c.reader, c.scope, "observations", %{}, c.now)

    request = %{
      "thing_id" => thing,
      "observation_id" => hd(observations["items"])["id"],
      "owner_confirmed" => true,
      "expected_generation" => "3"
    }

    for change <- [
          %{"owner_confirmed" => false},
          %{"thing_id" => "urn:uuid:invalid"},
          %{"observation_id" => ""},
          %{"expected_generation" => "03"},
          %{"unknown" => nil}
        ] do
      assert {:error, %{"code" => "invalid_request"}} =
               associate(c, Identifier.uuid(), Map.merge(request, change))
    end

    assert {:error, %{"code" => "forbidden"}} =
             associate(%{c | admin: c.reader}, Identifier.uuid(), request)

    assert {:error, %{"code" => "forbidden"}} =
             associate(%{c | scope: "other"}, Identifier.uuid(), request)

    assert {:error, %{"code" => "not_found"}} =
             associate(c, Identifier.uuid(), %{request | "observation_id" => "missing"})

    assert {:error, %{"code" => "not_found"}} =
             associate(c, Identifier.uuid(), %{
               request
               | "thing_id" => "urn:uuid:" <> Identifier.uuid()
             })

    assert {:error, %{"code" => "conflict"}} =
             associate(c, Identifier.uuid(), %{request | "expected_generation" => "2"})

    {:ok, imported} =
      Service.submit(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        import_request(%{id: "unknown", payload: {:bytes, <<>>}}, "3"),
        c.now
      )

    assert {:error, %{"code" => "unresolved"}} =
             associate(c, Identifier.uuid(), %{
               request
               | "observation_id" => imported["data"]["observation_id"],
                 "expected_generation" => "4"
             })
  end

  defp associate(c, operation, request),
    do: Service.associate(c.service, c.admin, c.scope, operation, request, c.now)

  defp read(c, thing),
    do:
      Service.read_property(
        c.service,
        c.reader,
        c.scope,
        thing,
        "temperature",
        Context.new!(request_id: "read"),
        c.now
      )
end
