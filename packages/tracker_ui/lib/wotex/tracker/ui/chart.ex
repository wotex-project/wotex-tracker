defmodule Wotex.Tracker.UI.Chart do
  @moduledoc "Projects one admitted numeric query result to bounded SVG geometry."

  @left 56.0
  @right 944.0
  @top 20.0
  @bottom 260.0

  @doc "Returns nil for an empty result and separate paths for every observed run."
  @spec project(map()) :: map() | nil
  def project(%{"spec" => spec, "series" => [%{"points" => points}]}) when points != [] do
    values = Enum.map(points, & &1["value"])
    minimum = Enum.min(values)
    maximum = Enum.max(values)
    scale = Enum.max([abs(minimum), abs(maximum), 1.0])
    {low, high} = extent(minimum / scale, maximum / scale)

    coordinates =
      Map.new(points, fn point ->
        x =
          @left +
            (point["start_at"] - spec["from_at"] +
               (point["end_at"] - point["start_at"]) / 2) /
              (spec["to_at"] - spec["from_at"]) * (@right - @left)

        y = @bottom - (point["value"] / scale - low) / (high - low) * (@bottom - @top)

        {point["start_at"],
         %{
           x: x,
           y: y,
           value: point["value"],
           start_at: point["start_at"],
           sample_count: point["sample_count"]
         }}
      end)

    %{
      points: Enum.map(points, &Map.fetch!(coordinates, &1["start_at"])),
      segments: Enum.map(runs(points), &paths(&1, coordinates)),
      minimum: minimum,
      maximum: maximum
    }
  end

  def project(_), do: nil

  defp extent(value, value), do: {value - 0.5, value + 0.5}
  defp extent(low, high), do: {low, high}

  defp runs(points) do
    {completed, current} =
      Enum.reduce(points, {[], []}, fn point, {completed, current} ->
        if current != [] and hd(current)["end_at"] != point["start_at"] do
          {[Enum.reverse(current) | completed], [point]}
        else
          {completed, [point | current]}
        end
      end)

    Enum.reverse([Enum.reverse(current) | completed])
  end

  defp paths(run, coordinates) do
    plotted = Enum.map(run, &Map.fetch!(coordinates, &1["start_at"]))
    [%{x: first_x} | _] = plotted
    %{x: last_x} = List.last(plotted)
    positions = Enum.map_join(plotted, " L ", &"#{format(&1.x)} #{format(&1.y)}")

    %{
      line: "M " <> positions,
      area:
        "M #{format(first_x)} #{format(@bottom)} L " <>
          positions <> " L #{format(last_x)} #{format(@bottom)} Z"
    }
  end

  defp format(value), do: :erlang.float_to_binary(value * 1.0, decimals: 2)
end
