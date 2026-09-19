defmodule Wotex.Tracker.UI.OperationalChart do
  @moduledoc """
  Projects a retained operational time window into discrete chart coordinates.

  `project/2` selects one nonnegative integer measurement from each sample and
  places it by elapsed time inside the disclosed window. It returns point
  positions and the observed value range, or `nil` when no plottable sample
  exists. The projection does not connect marks or infer measurements between
  recorded samples.
  """

  @left 56.0
  @right 944.0
  @top 20.0
  @bottom 260.0

  @doc "Plots retained values by elapsed time without implying values between samples."
  @spec project(map(), binary()) :: map() | nil
  def project(window, measurement) when is_binary(measurement) do
    case window(window) do
      {:ok, samples, from_at, to_at} ->
        samples
        |> Enum.flat_map(&measurement_point(&1, measurement, from_at, to_at))
        |> project_points(from_at, to_at)

      :error ->
        nil
    end
  end

  def project(_, _), do: nil

  defp window(%{"samples" => samples, "from_at" => from_at, "to_at" => to_at})
       when is_list(samples) and is_integer(from_at) and is_integer(to_at) and to_at > from_at,
       do: {:ok, samples, from_at, to_at}

  defp window(_), do: :error

  defp measurement_point(
         %{"event" => event, "observed_at" => observed, "measurements" => values},
         measurement,
         from_at,
         to_at
       )
       when is_integer(observed) and observed > from_at and observed <= to_at and is_map(values) do
    case values[measurement] do
      value when is_integer(value) and value >= 0 ->
        [%{event: event, observed_at: observed, value: value}]

      _ ->
        []
    end
  end

  defp measurement_point(_, _, _, _), do: []

  defp project_points([], _, _), do: nil

  defp project_points(points, from_at, to_at) do
    values = Enum.map(points, & &1.value)
    minimum = Enum.min(values)
    maximum = Enum.max(values)

    plotted =
      Enum.map(points, fn point ->
        x = @left + (point.observed_at - from_at) / (to_at - from_at) * (@right - @left)

        y =
          if maximum == minimum,
            do: (@top + @bottom) / 2,
            else: @bottom - (point.value - minimum) / (maximum - minimum) * (@bottom - @top)

        Map.merge(point, %{x: x, y: y})
      end)

    %{points: plotted, minimum: minimum, maximum: maximum, from_at: from_at, to_at: to_at}
  end
end
