defmodule Wotex.Tracker.UI.MapContext do
  @moduledoc """
  Projects an admitted offline map pack behind one retained route chart.

  Context is drawn only when the pack covers every retained route point. It
  does not alter route coordinates, segments, gaps, exports or continuity.
  """

  alias Wotex.Tracker.UI.{MapPack, RouteChart}

  @type status :: :available | :outside_coverage | :unconfigured
  @type t :: %{
          status: status(),
          attribution: String.t() | nil,
          id: String.t() | nil,
          revision: String.t() | nil,
          lines: [map()]
        }

  @doc "Returns a bounded presentation projection with an explicit coverage state."
  @spec project(MapPack.t() | nil, map() | nil) :: t()
  def project(nil, _chart), do: empty(:unconfigured)
  def project(%MapPack{}, nil), do: empty(:outside_coverage)

  def project(%MapPack{} = pack, %{segments: segments} = chart) when is_list(segments) do
    points = Enum.flat_map(segments, & &1.points)

    if points != [] and
         Enum.all?(points, &MapPack.covers?(pack, &1.latitude, &1.displayed_longitude)) do
      %{
        status: :available,
        attribution: pack.attribution,
        id: pack.id,
        revision: pack.revision,
        lines: Enum.map(pack.features, &project_feature(&1, chart))
      }
    else
      empty(:outside_coverage)
    end
  end

  def project(_, _), do: empty(:unconfigured)

  defp empty(status),
    do: %{status: status, attribution: nil, id: nil, revision: nil, lines: []}

  defp project_feature(feature, chart) do
    reference = chart.longitude |> then(fn {low, high} -> low + (high - low) / 2 end)

    points =
      feature.points
      |> Enum.reduce({[], reference}, fn {latitude, longitude}, {points, previous} ->
        longitude = unwrap(longitude, previous)
        point = RouteChart.project_coordinate(chart, latitude, longitude)
        {[point | points], longitude}
      end)
      |> elem(0)
      |> Enum.reverse()

    %{class: feature.class, line: line(points)}
  end

  defp unwrap(longitude, previous) do
    [longitude - 360, longitude, longitude + 360]
    |> Enum.min_by(&abs(&1 - previous))
    |> Kernel.*(1.0)
  end

  defp line(points) do
    positions = Enum.map_join(points, " L ", &"#{format(&1.x)} #{format(&1.y)}")
    "M " <> positions
  end

  defp format(value), do: :erlang.float_to_binary(value * 1.0, decimals: 2)
end
