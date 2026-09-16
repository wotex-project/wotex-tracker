defmodule Wotex.Tracker.UI.Chart do
  @moduledoc """
  Projects admitted query buckets into bounded SVG coordinates.

  `project/1` handles one series and `project_many/1` uses a common value
  scale for two to eight series. Both return `nil` when there are no points.
  Separate paths represent nonadjacent buckets, so a gap is not drawn as a
  continuous measurement. The exact values remain in the accompanying table.
  """

  @left 56.0
  @right 944.0
  @top 20.0
  @bottom 260.0

  @doc "Returns nil for an empty result and separate paths for every observed run."
  @spec project(map()) :: map() | nil
  def project(%{"spec" => spec, "series" => [%{"points" => points}]}) when points != [] do
    {minimum, maximum, scale, low, high} = bounds(Enum.map(points, & &1["value"]))

    Map.merge(project_points(spec, points, scale, low, high), %{
      minimum: minimum,
      maximum: maximum
    })
  end

  def project(_), do: nil

  @doc "Uses one common value scale for two to eight distinct named series."
  @spec project_many(map()) :: map() | nil
  def project_many(%{"spec" => spec, "series" => series}) when length(series) in 2..8 do
    values = for row <- series, point <- row["points"], do: point["value"]

    if values == [] do
      nil
    else
      {minimum, maximum, scale, low, high} = bounds(values)

      projected =
        Enum.map(series, fn row ->
          Map.merge(
            %{id: row["id"]},
            project_points(spec, row["points"], scale, low, high)
          )
        end)

      %{series: projected, minimum: minimum, maximum: maximum}
    end
  end

  def project_many(_), do: nil

  defp bounds(values) do
    minimum = Enum.min(values)
    maximum = Enum.max(values)
    scale = Enum.max([abs(minimum), abs(maximum), 1.0])
    {low, high} = extent(minimum / scale, maximum / scale)
    {minimum, maximum, scale, low, high}
  end

  defp project_points(_, [], _, _, _), do: %{points: [], segments: []}

  defp project_points(spec, points, scale, low, high) do
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
      segments: Enum.map(runs(points), &paths(&1, coordinates))
    }
  end

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
