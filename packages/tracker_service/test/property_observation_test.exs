defmodule Wotex.Tracker.PropertyObservationTest do
  use ExUnit.Case, async: true
  import Wotex.Tracker.Service.Fixtures
  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.{Identifier, PropertyObservation}

  test "snapshot handoff delivers only this Property's committed samples without a generation gap" do
    c = service()
    {thing, td} = materialized(c)
    assert td["properties"]["temperature"]["observable"]
    {:ok, access} = Service.authorize(c.service, c.reader, c.scope, "read", c.now)

    assert {:ok, initial} =
             PropertyObservation.open(c.service, access, thing, "temperature", nil, c.now)

    assert [%{"value" => 24.3, "generation" => "3"}] = initial["items"]

    assert {:ok, %{"items" => [], "closed" => false}} =
             PropertyObservation.batch(c.service, access, initial["cursor"], c.now)

    change(c, thing, "3", 6000)
    assert {:ok, page} = PropertyObservation.batch(c.service, access, initial["cursor"], c.now)
    assert [%{"value" => 30.0, "generation" => "6"}] = page["items"]
    refute page["closed"]

    assert {:ok, resumed} =
             PropertyObservation.open(
               c.service,
               access,
               thing,
               "temperature",
               initial["cursor"],
               c.now
             )

    assert Enum.map(resumed["items"], &Map.delete(&1, "cursor")) ==
             Enum.map(page["items"], &Map.delete(&1, "cursor"))

    assert {:ok, %{"items" => []}} =
             PropertyObservation.batch(c.service, access, page["cursor"], c.now)

    assert {:ok, %{"items" => [%{"value" => 100_044}]}} =
             PropertyObservation.open(c.service, access, thing, "pressure", nil, c.now)
  end

  test "cursors bind the selected Thing, Property, principal, instance, purpose and retention" do
    c = service()
    {thing, _} = materialized(c)
    {:ok, reader} = Service.authorize(c.service, c.reader, c.scope, "read", c.now)
    {:ok, admin} = Service.authorize(c.service, c.admin, c.scope, "read", c.now)
    {:ok, initial} = PropertyObservation.open(c.service, reader, thing, "temperature", nil, c.now)

    for {id, property} <- [{thing, "pressure"}, {"different", "temperature"}] do
      assert {:error, :invalid_cursor} =
               PropertyObservation.open(c.service, reader, id, property, initial["cursor"], c.now)
    end

    assert {:error, :invalid_cursor} =
             PropertyObservation.batch(c.service, admin, initial["cursor"], c.now)

    other = service()

    assert {:error, :invalid_cursor} =
             PropertyObservation.batch(other.service, reader, initial["cursor"], c.now)

    {:ok, snapshot} = Service.list(c.service, c.reader, c.scope, "things", %{}, c.now)

    assert {:error, :invalid_cursor} =
             PropertyObservation.batch(c.service, reader, snapshot["stream_cursor"], c.now)

    assert {:error, %{"code" => "invalid_cursor"}} =
             Service.events(c.service, c.reader, c.scope, initial["cursor"], c.now)

    assert {:error, :cursor_expired} =
             PropertyObservation.batch(c.service, reader, initial["cursor"], c.now + 604_800_000)

    assert {:error, :invalid_request} =
             PropertyObservation.open(c.service, reader, "", "temperature", nil, c.now)

    assert {:error, :not_found} =
             PropertyObservation.open(c.service, reader, thing, "missing", nil, c.now)

    {:ok, _} =
      Service.revoke(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        %{"credential_id" => "reader", "expected_generation" => "3"},
        c.now
      )

    assert {:error, :unauthorized} =
             PropertyObservation.batch(c.service, reader, initial["cursor"], c.now)
  end

  test "unavailable samples terminate replay without inventing a scalar or skipping the gap" do
    c = service()
    {thing, _} = materialized(c)
    {:ok, access} = Service.authorize(c.service, c.reader, c.scope, "read", c.now)
    {:ok, initial} = PropertyObservation.open(c.service, access, thing, "temperature", nil, c.now)
    change(c, thing, "3", 6100)
    change(c, thing, "6", 0x8000)

    assert {:error, :unavailable} =
             PropertyObservation.open(c.service, access, thing, "temperature", nil, c.now)

    change(c, thing, "9", 6200)
    assert {:ok, page} = PropertyObservation.batch(c.service, access, initial["cursor"], c.now)
    assert [%{"value" => 30.5, "generation" => "6"}] = page["items"]
    assert page["closed"]

    assert {:error, :unavailable} =
             PropertyObservation.open(
               c.service,
               access,
               thing,
               "temperature",
               page["cursor"],
               c.now
             )

    assert {:ok, %{"items" => [%{"value" => 31.0, "generation" => "12"}]}} =
             PropertyObservation.open(c.service, access, thing, "temperature", nil, c.now)
  end

  defp change(c, thing, generation, raw_temperature) do
    number = String.to_integer(generation)
    <<5, _::16, rest::binary>> = elem(observation().payload, 1)

    {:ok, receipt} =
      Service.submit(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        import_request(
          %{
            id: "sample-" <> generation,
            payload: {:bytes, <<5, raw_temperature::16, rest::binary>>}
          },
          generation
        ),
        c.now
      )

    {:ok, _} =
      Service.associate(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        %{
          "thing_id" => thing,
          "observation_id" => receipt["data"]["observation_id"],
          "owner_confirmed" => true,
          "expected_generation" => Integer.to_string(number + 1)
        },
        c.now
      )

    {:ok, _} =
      Service.materialize(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        %{"thing_id" => thing, "expected_generation" => Integer.to_string(number + 2)},
        c.now
      )
  end
end
