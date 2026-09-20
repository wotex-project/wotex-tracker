defmodule Wotex.Tracker.UI.MapPackTest do
  use ExUnit.Case, async: true

  alias Wotex.Tracker.UI.{MapContext, MapPack, RouteChart}

  test "admits bounded attributed line work and projects it only inside coverage" do
    assert {:ok, pack} = MapPack.new(document())
    refute inspect(pack) =~ "Local survey"
    refute inspect(pack) =~ "points"
    assert MapPack.covers?(pack, 59.33, 18.06)
    refute MapPack.covers?(pack, 60.1, 18.06)

    chart =
      RouteChart.project(%{
        "segments" => [%{"points" => [point("a", 59.33, 18.06), point("b", 59.34, 18.07)]}]
      })

    assert %{
             status: :available,
             id: "stockholm-core",
             revision: "2026-09",
             attribution: "Local survey",
             lines: [%{class: "road", line: "M " <> line}]
           } = MapContext.project(pack, chart)

    assert line =~ " L "

    outside =
      RouteChart.project(%{"segments" => [%{"points" => [point("c", 61.0, 18.06)]}]})

    assert %{status: :outside_coverage, lines: []} = MapContext.project(pack, outside)
    assert %{status: :unconfigured, lines: []} = MapContext.project(nil, chart)
  end

  test "supports an explicit antimeridian coverage rectangle" do
    crossing =
      document()
      |> put_in(["coverage"], %{
        "west" => 179.0,
        "south" => -10.0,
        "east" => -179.0,
        "north" => 10.0
      })
      |> put_in(["features", Access.at(0), "points"], [[0.0, 179.5], [0.0, -179.5]])

    assert {:ok, pack} = MapPack.new(crossing)
    assert MapPack.covers?(pack, 0, 179.9)
    assert MapPack.covers?(pack, 0, -179.9)
    refute MapPack.covers?(pack, 0, 0)

    chart =
      RouteChart.project(%{
        "segments" => [%{"points" => [point("a", 0, 179.8), point("b", 0, -179.8)]}]
      })

    assert %{status: :available, lines: [%{line: line}]} = MapContext.project(pack, chart)
    refute line =~ "-798"
  end

  test "rejects open, malformed and over-capacity documents" do
    valid = document()

    invalid = [
      Map.put(valid, "url", "https://tiles.example"),
      Map.put(valid, "schema", "wtr.map-pack.v2"),
      Map.put(valid, "id", <<0xFF>>),
      Map.put(valid, "revision", <<0xC3>>),
      Map.put(valid, "attribution", "line\nbreak"),
      put_in(valid, ["coverage", "west"], -181),
      put_in(valid, ["coverage", "east"], 17.0),
      put_in(valid, ["features", Access.at(0), "class"], "script"),
      put_in(valid, ["features", Access.at(0), "points"], [[59.3, 18.0]]),
      put_in(valid, ["features", Access.at(0), "points"], [[59.3, 18.0], [61.0, 18.0]]),
      Map.put(valid, "features", List.duplicate(hd(valid["features"]), 129))
    ]

    for document <- invalid do
      assert {:error, :invalid_map_pack} = MapPack.new(document)
    end
  end

  defp document do
    %{
      "schema" => "wtr.map-pack.v1",
      "id" => "stockholm-core",
      "revision" => "2026-09",
      "attribution" => "Local survey",
      "coverage" => %{"west" => 17.0, "south" => 59.0, "east" => 19.0, "north" => 60.0},
      "features" => [
        %{"class" => "road", "points" => [[59.32, 18.04], [59.36, 18.09]]}
      ]
    }
  end

  defp point(id, latitude, longitude),
    do: %{
      "id" => id,
      "latitude" => %{"value" => latitude},
      "longitude" => %{"value" => longitude},
      "event_at" => %{"value" => 1_700_000_000_000},
      "source" => "gnss",
      "quality" => "valid"
    }
end
