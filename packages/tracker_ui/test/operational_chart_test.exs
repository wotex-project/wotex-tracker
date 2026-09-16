defmodule Wotex.Tracker.UI.OperationalChartTest do
  @moduledoc false
  use ExUnit.Case, async: true
  alias Wotex.Tracker.UI.OperationalChart

  test "projects discrete values in record order without inventing missing measurements" do
    page = %{
      "samples" => [
        sample("query.stop", 100, %{"duration_us" => 10}),
        sample("runtime.sample", 101, %{"process_count" => 4}),
        sample("query.stop", 102, %{"duration_us" => 30})
      ]
    }

    chart = OperationalChart.project(page, "duration_us")
    assert {chart.minimum, chart.maximum} == {10, 30}
    assert Enum.map(chart.points, & &1.value) == [10, 30]
    assert Enum.map(chart.points, & &1.x) == [56.0, 944.0]
    assert Enum.map(chart.points, & &1.y) == [260.0, 20.0]
    refute Map.has_key?(chart, :line)
    assert OperationalChart.project(page, "unknown") == nil
  end

  test "a single or constant measurement stays centered" do
    one = %{"samples" => [sample("query.stop", 100, %{"duration_us" => 0})]}
    assert [%{x: 500.0, y: 140.0}] = OperationalChart.project(one, "duration_us").points

    equal = %{
      "samples" => [
        sample("query.stop", 100, %{"duration_us" => 5}),
        sample("query.stop", 101, %{"duration_us" => 5})
      ]
    }

    assert Enum.map(OperationalChart.project(equal, "duration_us").points, & &1.y) ==
             [140.0, 140.0]

    assert OperationalChart.project(%{"samples" => []}, "duration_us") == nil
  end

  defp sample(event, observed, measurements),
    do: %{"event" => event, "observed_at" => observed, "measurements" => measurements}
end
