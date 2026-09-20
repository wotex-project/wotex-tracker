defmodule Wotex.Tracker.CellularAssetTrackerModelTest do
  use ExUnit.Case, async: true

  alias Wotex.Tracker.Model
  alias Wotex.Tracker.Protocols.Teltonika.TAT140

  @path "priv/thing_models/cellular-asset-tracker-1.0.0.tm.json"

  test "the TAT140 profile resolves to one self-contained vendor-neutral model" do
    assert {:ok, document} = @path |> File.read!() |> Wotex.JSON.decode()
    assert {:ok, profile} = TAT140.profile()
    assert {:ok, model} = Model.new(document, profile.model)

    assert model.revision ==
             {"urn:wotex:tm:tracker:cellular-asset-tracker", "1.0.0"}

    assert document["@type"] == "tm:ThingModel"
    refute Map.has_key?(document, "tm:optional")
    refute inspect(document) =~ ~r/teltonika|tat140/i

    assert MapSet.new(Map.values(profile.mapping)) ==
             MapSet.new([
               "/properties/position",
               "/properties/motion",
               "/properties/batteryVoltage"
             ])

    assert Enum.all?(Map.values(profile.mapping), &property_pointer?(document, &1))
  end

  test "position, motion and voltage schemas preserve normalized units and bounds" do
    assert {:ok, document} = @path |> File.read!() |> Wotex.JSON.decode()
    properties = document["properties"]

    assert properties["motion"] == %{
             "type" => "boolean",
             "unit" => "1",
             "readOnly" => true
           }

    assert properties["batteryVoltage"] == %{
             "type" => "number",
             "minimum" => 0,
             "unit" => "V",
             "readOnly" => true
           }

    position = properties["position"]
    assert position["type"] == "object"
    assert position["unit"] == "WGS84"
    assert position["readOnly"]
    assert position["required"] == ["latitude", "longitude"]

    assert position["properties"] == %{
             "latitude" => %{
               "type" => "number",
               "minimum" => -90,
               "maximum" => 90,
               "unit" => "deg"
             },
             "longitude" => %{
               "type" => "number",
               "minimum" => -180,
               "maximum" => 180,
               "unit" => "deg"
             },
             "altitude" => %{
               "type" => "number",
               "minimum" => -100_000_000,
               "maximum" => 100_000_000,
               "unit" => "m"
             },
             "speed" => %{
               "type" => "number",
               "minimum" => 0,
               "maximum" => 100_000,
               "unit" => "m/s"
             },
             "horizontalAccuracy" => %{
               "type" => "number",
               "minimum" => 0,
               "maximum" => 40_100_000,
               "unit" => "m"
             }
           }
  end

  defp property_pointer?(document, "/properties/" <> name),
    do: Map.has_key?(document["properties"], name)

  defp property_pointer?(_document, _pointer), do: false
end
