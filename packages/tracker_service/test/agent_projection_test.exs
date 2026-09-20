defmodule Wotex.Tracker.Service.AgentProjectionTest do
  use ExUnit.Case, async: true

  import Wotex.Tracker.Service.Fixtures

  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.AgentProjection

  test "current readers project only explicitly disclosed read affordances" do
    context = service()
    {thing, _td} = materialized(context)
    request = request(thing, "3", ~w(temperature pressure), [])

    assert {:ok, projection} =
             Service.agent_tools(
               context.service,
               context.reader,
               context.scope,
               request,
               context.now
             )

    assert projection["schema"] == "wtr.agent-tools.v1"
    assert projection["thing"] == %{"id" => thing, "generation" => "3"}
    assert Enum.map(projection["tools"], & &1["name"]) == ~w(pressure temperature)

    pressure = Enum.find(projection["tools"], &(&1["name"] == "pressure"))
    temperature = Enum.find(projection["tools"], &(&1["name"] == "temperature"))

    assert pressure["output_schema"] == %{"type" => "integer", "unit" => "Pa"}
    assert temperature["output_schema"] == %{"type" => "number", "unit" => "Cel"}
    assert pressure["thing_id"] == thing
    assert pressure["thing_generation"] == "3"
    assert pressure["kind"] == "property"
    assert pressure["operation"] == "read"
    assert String.starts_with?(pressure["id"], "wtrtool1_")
    refute pressure["id"] == temperature["id"]

    encoded = Jason.encode!(projection)
    refute encoded =~ "forms"
    refute encoded =~ "href"
    refute encoded =~ "127.0.0.1"
    refute encoded =~ context.reader
    refute encoded =~ "observation-1"
  end

  test "authority and the current Thing generation are rechecked before projection" do
    context = service()
    {thing, _td} = materialized(context)

    assert {:error, %{"code" => "unauthorized"}} =
             Service.agent_tools(
               context.service,
               "invalid",
               context.scope,
               request(thing, "3", ["temperature"], []),
               context.now
             )

    assert {:error, %{"code" => "revision_mismatch"}} =
             Service.agent_tools(
               context.service,
               context.reader,
               context.scope,
               request(thing, "2", ["temperature"], []),
               context.now
             )

    assert {:error, %{"code" => "not_found"}} =
             Service.agent_tools(
               context.service,
               context.reader,
               context.scope,
               request(thing, "3", ["missing"], []),
               context.now
             )
  end

  test "actions remain proposals and preserve admitted primitive numeric constraints" do
    context = service()
    {thing, td} = materialized(context)

    action = %{
      "input" => %{"type" => "integer", "minimum" => 0, "maximum" => 10},
      "output" => %{"type" => "number", "minimum" => 0.25},
      "forms" => [
        %{
          "href" => "http://127.0.0.1:45678/actions/diagnose",
          "op" => "invokeaction",
          "contentType" => "application/json"
        }
      ]
    }

    td = Map.put(td, "actions", %{"diagnose" => action})
    assert {:ok, _} = Wotex.ThingDescription.from_map(td)

    assert {:ok, projection} =
             AgentProjection.project(td, "3", request(thing, "3", [], ["diagnose"]))

    assert [tool] = projection["tools"]
    assert tool["mode"] == "proposal"
    assert tool["operation"] == "proposal"

    assert tool["input_schema"] == %{
             "type" => "integer",
             "minimum" => 0,
             "maximum" => 10
           }

    assert tool["output_schema"] == %{"type" => "number", "minimum" => 0.25}
    refute Jason.encode!(tool) =~ "invokeaction"
    refute Jason.encode!(tool) =~ "href"

    assert {:ok, %{"tools" => []}} =
             AgentProjection.project(td, "3", request(thing, "3", [], []))
  end

  test "open, duplicate and unsupported disclosures fail closed" do
    context = service()
    {thing, td} = materialized(context)

    for invalid <- [
          Map.put(request(thing, "3", [], []), "extra", true),
          request(thing, "03", [], []),
          request(thing, "3", ["temperature", "temperature"], []),
          request(thing, "3", ["bad\nname"], [])
        ] do
      assert {:error, :invalid_request} = AgentProjection.admit(invalid)
    end

    object =
      td
      |> put_in(["properties", "temperature", "type"], "object")
      |> put_in(["properties", "temperature", "properties"], %{
        "value" => %{"type" => "number"}
      })

    assert {:ok, _} = Wotex.ThingDescription.from_map(object)

    assert {:error, :unsupported} =
             AgentProjection.project(object, "3", request(thing, "3", ["temperature"], []))

    writable = put_in(td, ["properties", "temperature", "readOnly"], false)

    assert {:error, :unsupported} =
             AgentProjection.project(writable, "3", request(thing, "3", ["temperature"], []))
  end

  test "admission bounds identifiers, names and total disclosure size" do
    thing = "urn:uuid:00000000-0000-4000-8000-000000000001"

    for invalid <- [
          nil,
          request("urn:uuid:invalid", "3", [], []),
          request(thing, "3", "temperature", []),
          request(thing, "3", [], "diagnose"),
          request(thing, "3", [String.duplicate("a", 129)], []),
          request(
            thing,
            "3",
            Enum.map(1..17, &"property-#{&1}"),
            Enum.map(1..16, &"action-#{&1}")
          )
        ] do
      assert {:error, :invalid_request} = AgentProjection.admit(invalid)
    end
  end

  test "the pure projection rejects invalid documents, identities and revisions" do
    context = service()
    {thing, td} = materialized(context)
    disclosure = request(thing, "3", [], [])

    assert {:error, :invalid_request} = AgentProjection.project(nil, "3", disclosure)
    assert {:error, :invalid_request} = AgentProjection.project(%{}, "3", disclosure)
    assert {:error, :revision_mismatch} = AgentProjection.project(td, "2", disclosure)

    other_thing = "urn:uuid:00000000-0000-4000-8000-000000000002"

    assert {:error, :revision_mismatch} =
             AgentProjection.project(Map.put(td, "id", other_thing), "3", disclosure)
  end

  test "optional action schemas and form operation lists stay closed" do
    context = service()
    {thing, td} = materialized(context)

    action = %{
      "forms" => [
        %{
          "href" => "http://127.0.0.1:45678/actions/refresh",
          "op" => ["invokeaction"]
        }
      ]
    }

    td = Map.put(td, "actions", %{"refresh" => action})

    assert {:ok, %{"tools" => [tool]}} =
             AgentProjection.project(td, "3", request(thing, "3", [], ["refresh"]))

    assert tool["input_schema"] == nil
    assert tool["output_schema"] == nil
  end

  test "string and boolean projections admit only their closed primitive constraints" do
    context = service()
    {thing, td} = materialized(context)

    text = %{
      "type" => "string",
      "readOnly" => true,
      "minLength" => 1,
      "maxLength" => 12,
      "pattern" => "^[a-z]+$",
      "forms" => [property_form("label")]
    }

    active = %{
      "type" => "boolean",
      "readOnly" => true,
      "forms" => [property_form("active")]
    }

    td = Map.update!(td, "properties", &Map.merge(&1, %{"label" => text, "active" => active}))

    assert {:ok, %{"tools" => tools}} =
             AgentProjection.project(td, "3", request(thing, "3", ~w(label active), []))

    assert Enum.find(tools, &(&1["name"] == "active"))["output_schema"] == %{
             "type" => "boolean"
           }

    assert Enum.find(tools, &(&1["name"] == "label"))["output_schema"] == %{
             "type" => "string",
             "minLength" => 1,
             "maxLength" => 12,
             "pattern" => "^[a-z]+$"
           }

    empty_pattern = put_in(td, ["properties", "label", "pattern"], "")

    assert {:error, :unsupported} =
             AgentProjection.project(
               empty_pattern,
               "3",
               request(thing, "3", ["label"], [])
             )
  end

  defp request(thing, generation, properties, actions),
    do: %{
      "schema" => "wtr.agent-projection-request.v1",
      "thing_id" => thing,
      "expected_generation" => generation,
      "read_properties" => properties,
      "propose_actions" => actions
    }

  defp property_form(name),
    do: %{
      "href" => "http://127.0.0.1:45678/properties/#{name}",
      "op" => "readproperty"
    }
end
