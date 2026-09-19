defmodule Wotex.Tracker.UI.OperationalChartTest do
  @moduledoc false
  use ExUnit.Case, async: true
  alias Wotex.Tracker.UI.OperationalChart

  test "projects discrete values by elapsed time without inventing missing measurements" do
    window = %{
      "from_at" => 100,
      "to_at" => 200,
      "samples" => [
        sample("query.stop", 110, %{"duration_us" => 10}),
        sample("runtime.sample", 150, %{"process_count" => 4}),
        sample("query.stop", 190, %{"duration_us" => 30})
      ]
    }

    chart = OperationalChart.project(window, "duration_us")
    assert {chart.minimum, chart.maximum} == {10, 30}
    assert Enum.map(chart.points, & &1.value) == [10, 30]
    assert Enum.map(chart.points, & &1.x) == [144.8, 855.2]
    assert Enum.map(chart.points, & &1.y) == [260.0, 20.0]
    refute Map.has_key?(chart, :line)
    assert OperationalChart.project(window, "unknown") == nil
  end

  test "a single or constant measurement retains elapsed position and centers its value" do
    one = %{
      "from_at" => 100,
      "to_at" => 200,
      "samples" => [sample("query.stop", 125, %{"duration_us" => 0})]
    }

    assert [%{x: 278.0, y: 140.0}] = OperationalChart.project(one, "duration_us").points

    equal = %{
      "from_at" => 100,
      "to_at" => 200,
      "samples" => [
        sample("query.stop", 110, %{"duration_us" => 5}),
        sample("query.stop", 190, %{"duration_us" => 5})
      ]
    }

    assert Enum.map(OperationalChart.project(equal, "duration_us").points, & &1.y) ==
             [140.0, 140.0]

    assert OperationalChart.project(
             %{"from_at" => 100, "to_at" => 200, "samples" => []},
             "duration_us"
           ) == nil

    assert OperationalChart.project(%{"samples" => []}, "duration_us") == nil
  end

  defp sample(event, observed, measurements),
    do: %{"event" => event, "observed_at" => observed, "measurements" => measurements}
end
