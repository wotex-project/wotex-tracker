defmodule Wotex.Tracker.UI.OperationalChart do
  @moduledoc """
  Projects a page of operational samples into discrete chart coordinates.

  `project/2` selects one nonnegative integer measurement from each sample and
  keeps the samples in page order. It returns point positions and the observed
  value range, or `nil` when no plottable sample exists. The projection does
  not connect marks or infer measurements between recorded samples.
  """

  @left 56.0
  @right 944.0
  @top 20.0
  @bottom 260.0

  @doc "Plots retained values in record order without implying values between samples."
  @spec project(map(), binary()) :: map() | nil
  def project(%{"samples" => samples}, measurement)
      when is_list(samples) and is_binary(measurement) do
    points =
      for %{"event" => event, "observed_at" => observed, "measurements" => values} <- samples,
          is_map(values),
          value = values[measurement],
          is_integer(value) and value >= 0 do
        %{event: event, observed_at: observed, value: value}
      end

    project_points(points)
  end

  def project(_, _), do: nil

  defp project_points([]), do: nil

  defp project_points(points) do
    values = Enum.map(points, & &1.value)
    minimum = Enum.min(values)
    maximum = Enum.max(values)
    last = length(points) - 1

    plotted =
      points
      |> Enum.with_index()
      |> Enum.map(fn {point, index} ->
        x = if last == 0, do: (@left + @right) / 2, else: @left + index / last * (@right - @left)

        y =
          if maximum == minimum,
            do: (@top + @bottom) / 2,
            else: @bottom - (point.value - minimum) / (maximum - minimum) * (@bottom - @top)

        Map.merge(point, %{x: x, y: y})
      end)

    %{points: plotted, minimum: minimum, maximum: maximum}
  end
end
