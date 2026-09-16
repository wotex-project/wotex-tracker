defmodule Wotex.Tracker.UI.ChartTest do
  use ExUnit.Case, async: true
  alias Wotex.Tracker.UI.Chart

  test "separate SVG paths preserve unobserved bucket gaps and an exact zero" do
    result = %{
      "spec" => %{"from_at" => 0, "to_at" => 1_000},
      "series" => [
        %{
          "points" => [
            point(0, 100, 0),
            point(100, 200, 10),
            point(400, 500, -10)
          ]
        }
      ]
    }

    chart = Chart.project(result)
    assert length(chart.points) == 3
    assert length(chart.segments) == 2
    assert hd(chart.segments).line =~ " L "
    refute List.last(chart.segments).line =~ " L "
    assert hd(chart.segments).area =~ " Z"
    assert chart.minimum == -10
    assert chart.maximum == 10
    assert Enum.any?(chart.points, &(&1.value === 0))
  end

  test "a constant or empty series does not divide by zero or invent points" do
    assert Chart.project(%{"spec" => %{}, "series" => [%{"points" => []}]}) == nil

    result = %{
      "spec" => %{"from_at" => 0, "to_at" => 100},
      "series" => [%{"points" => [point(0, 100, 1.0e308)]}]
    }

    chart = Chart.project(result)
    assert length(chart.segments) == 1
    assert chart.points |> hd() |> Map.fetch!(:y) == 140.0
    refute hd(chart.segments).line =~ "inf"
  end

  defp point(start_at, end_at, value),
    do: %{"start_at" => start_at, "end_at" => end_at, "value" => value, "sample_count" => 1}
end
