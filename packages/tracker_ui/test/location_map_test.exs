defmodule Wotex.Tracker.UI.LocationMapTest do
  use ExUnit.Case, async: true
  alias Wotex.Tracker.UI.LocationMap

  test "keeps every available asset claim as a separate marker" do
    map =
      LocationMap.project([
        entry("bike", "Cargo bike", 59.3293, 18.0686),
        %{
          entry("trailer", "Trailer", 59.34, 18.08)
          | positions: [position(59.34, 18.08), position(59.35, 18.09)]
        }
      ])

    assert map.asset_count == 2
    assert map.claim_count == 3
    assert Enum.map(map.markers, & &1.index) == [1, 2, 3]
    assert Enum.map(map.markers, & &1.title) == ["Cargo bike", "Trailer", "Trailer"]
    assert Enum.all?(map.markers, &(is_number(&1.x) and is_number(&1.y)))
    assert length(map.chart.segments) == 3
  end

  test "ignores unavailable and malformed claims without inventing a marker" do
    unavailable = %{position(59.0, 18.0) | "availability" => "unavailable"}
    malformed = %{position(59.0, 18.0) | "latitude" => %{"value" => 91}}

    assert LocationMap.project([
             %{entry("bike", "Cargo bike", 59.0, 18.0) | positions: [unavailable, malformed]}
           ]) == nil

    assert LocationMap.project(:invented) == nil
  end

  test "unwraps current claims across the antimeridian" do
    map =
      LocationMap.project([
        entry("west", "West", 10.0, 179.9),
        entry("east", "East", 10.1, -179.9)
      ])

    assert_in_delta elem(map.chart.longitude, 0), 179.9, 0.000_001
    assert_in_delta elem(map.chart.longitude, 1), 180.1, 0.000_001
  end

  defp entry(id, title, latitude, longitude),
    do: %{
      id: id,
      title: title,
      href: "/assets/" <> id,
      observed_at: %{"value" => 1_700_000_000_000},
      positions: [position(latitude, longitude)]
    }

  defp position(latitude, longitude),
    do: %{
      "availability" => "available",
      "latitude" => %{"value" => latitude},
      "longitude" => %{"value" => longitude},
      "source" => "gnss",
      "quality" => "valid",
      "fix_at" => %{"value" => 1_700_000_000_000},
      "received_at" => %{"value" => 1_700_000_000_100},
      "accuracy_kind" => "bound",
      "horizontal_accuracy_m" => %{"value" => 5.0}
    }
end
