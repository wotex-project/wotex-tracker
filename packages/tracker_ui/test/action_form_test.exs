defmodule Wotex.Tracker.UI.ActionFormTest do
  @moduledoc false
  use ExUnit.Case, async: true
  alias Wotex.Tracker.UI.ActionForm

  @operation "2f8e7a8c-ea0f-4bf1-918e-b0852b124a72"
  @thing "urn:uuid:6ba7b810-9dad-41d1-80b4-00c04fd430c8"

  test "projects bounded primitive Actions without execution Forms" do
    assert {:ok, []} = ActionForm.actions(%{})

    thing = %{
      "actions" => %{
        "toggle" => action(%{"type" => "boolean"}),
        "refresh" => action(%{"type" => "integer", "minimum" => 1, "maximum" => 10})
      }
    }

    assert {:ok, [refresh, toggle]} = ActionForm.actions(thing)
    assert refresh["name"] == "refresh"
    assert refresh["title"] == "Refresh now"
    assert refresh["description"] == "Requests one fresh report"
    assert refresh["supported"]
    assert refresh["input"] == %{"type" => "integer", "minimum" => 1, "maximum" => 10}
    refute inspect([refresh, toggle]) =~ "device.invalid"
    refute Map.has_key?(refresh, "forms")

    unsupported = %{"actions" => %{"code" => action(%{"type" => "string", "pattern" => "x"})}}
    assert {:ok, [%{"supported" => false}]} = ActionForm.actions(unsupported)
  end

  test "malformed and unbounded declarations fail closed" do
    invalid = [
      %{"actions" => []},
      %{"actions" => %{"bad\nname" => action(nil)}},
      %{"actions" => %{"missing-form" => Map.delete(action(nil), "forms")}},
      %{"actions" => %{"bad-title" => %{action(nil) | "title" => String.duplicate("x", 513)}}},
      %{"actions" => %{"object" => action(%{"type" => "object"})}}
    ]

    for thing <- invalid do
      assert {:error, :invalid_actions} = ActionForm.actions(thing)
    end

    too_many = for index <- 1..65, into: %{}, do: {"action-#{index}", action(nil)}
    assert {:error, :invalid_actions} = ActionForm.actions(%{"actions" => too_many})
  end

  test "decodes only exact service-supported primitive inputs" do
    assert {:ok, nil} = ActionForm.decode_input(nil, nil)
    assert {:ok, true} = ActionForm.decode_input(%{"type" => "boolean"}, "true")
    assert {:ok, false} = ActionForm.decode_input(%{"type" => "boolean"}, "false")

    assert {:ok, 5} =
             ActionForm.decode_input(
               %{"type" => "integer", "minimum" => 1, "maximum" => 10},
               "5"
             )

    assert {:ok, 1.5} = ActionForm.decode_input(%{"type" => "number"}, "1.5")
    assert {:ok, ""} = ActionForm.decode_input(%{"type" => "string", "minLength" => 0}, "")

    for {schema, value} <- [
          {%{"type" => "boolean"}, "yes"},
          {%{"type" => "integer"}, "1.0"},
          {%{"type" => "integer", "maximum" => 1}, "2"},
          {%{"type" => "number"}, "NaN"},
          {%{"type" => "string", "maxLength" => 1}, "long"},
          {%{"type" => "string", "pattern" => "x"}, "x"},
          {nil, "value"}
        ] do
      assert {:error, :invalid_input} = ActionForm.decode_input(schema, value)
    end
  end

  test "admits only an exact identity-matched public Action status" do
    queued = status()
    assert ActionForm.status?(queued, @operation, @thing, "refresh")

    accepted = %{
      queued
      | "status" => "accepted",
        "claimed_at" => 2,
        "settled_at" => 3,
        "outcome" => %{"classification" => "protocol_accepted", "completed_at" => 3},
        "physical_effect" => "unknown"
    }

    assert ActionForm.status?(accepted, @operation, @thing, "refresh")

    for invalid <- [
          Map.put(queued, "input", "private"),
          put_in(queued, ["thing", "id"], "other"),
          %{queued | "operation_id" => "bad"},
          %{queued | "action" => "other"},
          %{queued | "status" => "accepted"},
          %{queued | "physical_effect" => "unknown"},
          %{queued | "outcome" => %{"classification" => "invented"}}
        ] do
      refute ActionForm.status?(invalid, @operation, @thing, "refresh")
    end
  end

  defp action(input),
    do: %{
      "title" => "Refresh now",
      "description" => "Requests one fresh report",
      "input" => input,
      "forms" => [
        %{
          "href" => "https://device.invalid/actions/refresh",
          "op" => ["invokeaction"]
        }
      ]
    }

  defp status,
    do: %{
      "schema" => "wtr.action-status.v1",
      "operation_id" => @operation,
      "thing" => %{"id" => @thing, "generation" => "4"},
      "action" => "refresh",
      "status" => "queued",
      "admitted_at" => 1,
      "claimed_at" => nil,
      "settled_at" => nil,
      "outcome" => nil,
      "physical_effect" => "not_dispatched"
    }
end
