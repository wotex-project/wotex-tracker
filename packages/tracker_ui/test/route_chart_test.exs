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

    [first, second] = hd(chart.segments).points
    assert_in_delta first.longitude, 179.9, 0.000_001
    assert_in_delta second.longitude, 180.1, 0.000_001
    assert second.displayed_longitude == -179.9
  end

  test "constant coordinates remain plottable while empty and malformed routes do not" do
    chart = RouteChart.project(%{"segments" => [%{"points" => [point("zero", 0, 0)]}]})
    assert [%{points: [%{x: 500.0, y: 200.0}]}] = chart.segments

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
