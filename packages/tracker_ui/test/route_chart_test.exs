defmodule Wotex.Tracker.UI.RouteChartTest do
  use ExUnit.Case, async: true
  alias Wotex.Tracker.UI.RouteChart

  test "keeps service segments separate and unwraps an antimeridian crossing" do
    route = %{
      "segments" => [
        %{"points" => [point("a", 10.0, 179.9), point("b", 10.1, -179.9)]},
        %{"points" => [point("c", 11.0, -179.8)]}
      ]
    }

    chart = RouteChart.project(route)
    assert length(chart.segments) == 2
    assert hd(chart.segments).line =~ " L "
    refute List.last(chart.segments).line =~ " L "
    assert_in_delta elem(chart.longitude, 0), 179.9, 0.000_001
    assert_in_delta elem(chart.longitude, 1), 180.2, 0.000_001

    assert Enum.map(chart.longitude_ticks, & &1.label) == [
             "179.90000° E",
             "179.97500° E",
             "179.95000° W",
             "179.87500° W",
             "179.80000° W"
           ]

    assert Enum.map(chart.latitude_ticks, & &1.label) == [
             "10.000° N",
             "10.250° N",
             "10.500° N",
             "10.750° N",
             "11.000° N"
           ]

    [first, second] = hd(chart.segments).points
    assert_in_delta first.longitude, 179.9, 0.000_001
    assert_in_delta second.longitude, 180.1, 0.000_001
    assert second.displayed_longitude == -179.9
  end

  test "constant coordinates remain plottable while empty and malformed routes do not" do
    chart = RouteChart.project(%{"segments" => [%{"points" => [point("zero", 0, 0)]}]})
    assert [%{points: [%{x: 500.0, y: 200.0}]}] = chart.segments

    assert Enum.map(chart.longitude_ticks, & &1.label) ==
             ~w(0.500°_W 0.250°_W 0.000° 0.250°_E 0.500°_E)
             |> Enum.map(&String.replace(&1, "_", " "))

    assert RouteChart.project(%{"segments" => []}) == nil
    assert RouteChart.project(%{"segments" => [%{"points" => []}]}) == nil

    assert RouteChart.project(%{
             "segments" => [%{"points" => [point("bad", 91, 0)]}]
           }) == nil
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
