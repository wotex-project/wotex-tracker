defmodule Wotex.Tracker.UI.RouteChart do
  @moduledoc """
  Projects one public route page into a bounded coordinate SVG.

  Service segments remain separate and therefore never gain a visual connector.
  Segment starts share the first point's longitude frame, then each segment is
  unwrapped independently so a qualified antimeridian crossing uses its short
  delta without gaining a connector. A bounded latitude/longitude graticule
  makes the projection geographically inspectable without a basemap. The
  projection supplies no road match, interpolation or cross-page continuity.
  """

  @left 56.0
  @right 944.0
  @top 24.0
  @bottom 376.0
  @tick_intervals 4

  @doc "Returns nil for empty or malformed public routes."
  @spec project(term()) :: map() | nil
  def project(%{"segments" => segments}) when is_list(segments) do
    with {:ok, segments} <- segments(segments),
         [_ | _] = points <- Enum.flat_map(segments, & &1) do
      project_segments(segments, points)
    else
      _ -> nil
    end
  end

  def project(_), do: nil

  @doc "Projects one already-unwrapped coordinate into an existing route chart."
  @spec project_coordinate(map(), number(), number()) :: %{x: float(), y: float()}
  def project_coordinate(
        %{longitude: {longitude_low, longitude_high}, latitude: {latitude_low, latitude_high}},
        latitude,
        longitude
      )
      when is_number(latitude) and is_number(longitude) do
    %{
      x: scale(longitude, longitude_low, longitude_high, @left, @right),
      y: scale(latitude, latitude_low, latitude_high, @bottom, @top)
    }
  end

  defp project_segments(segments, points) do
    {longitude_low, longitude_high} = extent(Enum.map(points, & &1.longitude))
    {latitude_low, latitude_high} = extent(Enum.map(points, & &1.latitude))

    projected =
      Enum.map(segments, fn segment ->
        points =
          Enum.map(segment, fn point ->
            Map.merge(
              point,
              project_coordinate(
                %{
                  longitude: {longitude_low, longitude_high},
                  latitude: {latitude_low, latitude_high}
                },
                point.latitude,
                point.longitude
              )
            )
          end)

        %{line: line(points), points: points}
      end)

    %{
      segments: projected,
      longitude: {longitude_low, longitude_high},
      latitude: {latitude_low, latitude_high},
      longitude_ticks: longitude_ticks(longitude_low, longitude_high, @left, @right),
      latitude_ticks: latitude_ticks(latitude_low, latitude_high, @bottom, @top)
    }
  end

  defp longitude_ticks(low, high, output_low, output_high) do
    decimals = decimals(high - low)

    ticks(low, high, output_low, output_high, fn value, position ->
      %{x: position, label: coordinate_label(normalize_longitude(value), :longitude, decimals)}
    end)
  end

  defp latitude_ticks(low, high, output_low, output_high) do
    decimals = decimals(high - low)

    ticks(low, high, output_low, output_high, fn value, position ->
      %{y: position, label: coordinate_label(value, :latitude, decimals)}
    end)
  end

  defp ticks(low, high, output_low, output_high, project) do
    Enum.map(0..@tick_intervals, fn index ->
      ratio = index / @tick_intervals
      value = low + (high - low) * ratio
      project.(value, output_low + (output_high - output_low) * ratio)
    end)
  end

  defp decimals(span) when span >= 10, do: 2
  defp decimals(span) when span >= 1, do: 3
  defp decimals(_), do: 5

  defp normalize_longitude(value) do
    normalized = value - 360 * :math.floor((value + 180) / 360)
    if normalized == -180.0 and value > 0, do: 180.0, else: normalized
  end

  defp coordinate_label(value, axis, decimals) do
    direction = direction(value, axis)
    number = :erlang.float_to_binary(abs(value * 1.0), decimals: decimals)
    if direction == "", do: number <> "°", else: number <> "° " <> direction
  end

  defp direction(value, :latitude) when value > 0, do: "N"
  defp direction(value, :latitude) when value < 0, do: "S"
  defp direction(value, :longitude) when value > 0, do: "E"
  defp direction(value, :longitude) when value < 0, do: "W"
  defp direction(_, _), do: ""

  defp segments(values) do
    Enum.reduce_while(values, {:ok, [], nil}, fn value, {:ok, acc, reference} ->
      case segment(value, reference) do
        {:ok, points} ->
          reference = reference || hd(points).longitude
          {:cont, {:ok, [points | acc], reference}}

        :error ->
          {:halt, :error}
      end
    end)
    |> case do
      {:ok, values, _} -> {:ok, Enum.reverse(values)}
      :error -> :error
    end
  end

  defp segment(%{"points" => [_ | _] = points}, reference) do
    points
    |> Enum.reduce_while({:ok, [], reference}, fn point, {:ok, acc, previous} ->
      case coordinate(point, previous) do
        {:ok, value} -> {:cont, {:ok, [value | acc], value.longitude}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, values, _} -> {:ok, Enum.reverse(values)}
      :error -> :error
    end
  end

  defp segment(_, _), do: :error

  defp coordinate(
         %{
           "id" => id,
           "latitude" => %{"value" => latitude},
           "longitude" => %{"value" => longitude},
           "event_at" => event_at,
           "source" => source,
           "quality" => quality
         },
         previous
       ) do
    if coordinate?(id, latitude, longitude, event_at, source, quality) do
      {:ok,
       %{
         id: id,
         latitude: latitude,
         longitude: unwrap(longitude, previous),
         displayed_longitude: longitude,
         event_at: event_at,
         source: source,
         quality: quality
       }}
    else
      :error
    end
  end

  defp coordinate(_, _), do: :error

  defp coordinate?(id, latitude, longitude, event_at, source, quality),
    do:
      is_binary(id) and latitude?(latitude) and longitude?(longitude) and is_map(event_at) and
        is_binary(source) and is_binary(quality)

  defp latitude?(value), do: is_number(value) and value >= -90 and value <= 90
  defp longitude?(value), do: is_number(value) and value >= -180 and value <= 180

  defp unwrap(longitude, nil), do: longitude * 1.0

  defp unwrap(longitude, previous) do
    [longitude - 360, longitude, longitude + 360]
    |> Enum.min_by(&abs(&1 - previous))
    |> Kernel.*(1.0)
  end

  defp extent(values) do
    low = Enum.min(values) * 1.0
    high = Enum.max(values) * 1.0

    if low == high, do: {low - 0.5, high + 0.5}, else: {low, high}
  end

  defp scale(value, low, high, output_low, output_high),
    do: output_low + (value - low) / (high - low) * (output_high - output_low)

  defp line(points) do
    positions = Enum.map_join(points, " L ", &"#{format(&1.x)} #{format(&1.y)}")
    "M " <> positions
  end

  defp format(value), do: :erlang.float_to_binary(value * 1.0, decimals: 2)
end
