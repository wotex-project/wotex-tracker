defmodule Wotex.Tracker.UI.RouteViewport do
  @moduledoc """
  Bounds the interactive viewport for the route evidence map.

  The viewport changes only presentation. It never alters route coordinates,
  joins service segments or requests a different retained-data snapshot.
  """

  @width 1_000.0
  @height 400.0
  @minimum_zoom 1
  @maximum_zoom 8
  @zooms [1, 2, 4, 8]
  @commands ~w(reset zoom-in zoom-out pan-left pan-right pan-up pan-down)

  @type t :: %{center_x: float(), center_y: float(), zoom: pos_integer()}

  @doc "Returns the complete route-map viewport."
  @spec new() :: t()
  def new, do: %{center_x: @width / 2, center_y: @height / 2, zoom: @minimum_zoom}

  @doc "Applies one closed zoom, pan or reset command."
  @spec update(t(), String.t()) :: {:ok, t()} | :error
  def update(viewport, command) when command in @commands do
    if valid?(viewport), do: apply_command(viewport, command), else: :error
  end

  def update(_, _), do: :error

  defp apply_command(_viewport, "reset"), do: {:ok, new()}

  defp apply_command(%{zoom: zoom} = viewport, "zoom-in") when zoom < @maximum_zoom,
    do: {:ok, clamp(%{viewport | zoom: zoom * 2})}

  defp apply_command(%{zoom: zoom} = viewport, "zoom-out") when zoom > @minimum_zoom,
    do: {:ok, clamp(%{viewport | zoom: div(zoom, 2)})}

  defp apply_command(viewport, "zoom-in"), do: {:ok, viewport}
  defp apply_command(viewport, "zoom-out"), do: {:ok, viewport}
  defp apply_command(viewport, "pan-left"), do: pan(viewport, -1, 0)
  defp apply_command(viewport, "pan-right"), do: pan(viewport, 1, 0)
  defp apply_command(viewport, "pan-up"), do: pan(viewport, 0, -1)
  defp apply_command(viewport, "pan-down"), do: pan(viewport, 0, 1)

  @doc "Returns a bounded SVG viewBox string."
  @spec view_box(t()) :: String.t()
  def view_box(%{center_x: center_x, center_y: center_y, zoom: zoom})
      when zoom in @zooms do
    width = @width / zoom
    height = @height / zoom

    Enum.map_join(
      [center_x - width / 2, center_y - height / 2, width, height],
      " ",
      &format/1
    )
  end

  @doc "Returns a short accessible description of the current viewport."
  @spec label(t()) :: String.t()
  def label(%{zoom: zoom}), do: "Map zoom #{zoom}×"

  defp pan(%{zoom: zoom} = viewport, horizontal, vertical)
       when zoom in @zooms do
    width = @width / zoom
    height = @height / zoom

    {:ok,
     clamp(%{
       viewport
       | center_x: viewport.center_x + horizontal * width / 4,
         center_y: viewport.center_y + vertical * height / 4
     })}
  end

  defp pan(_, _, _), do: :error

  defp clamp(%{zoom: zoom} = viewport) when zoom in @zooms do
    half_width = @width / zoom / 2
    half_height = @height / zoom / 2

    %{
      viewport
      | center_x: bounded(viewport.center_x, half_width, @width - half_width),
        center_y: bounded(viewport.center_y, half_height, @height - half_height)
    }
  end

  defp bounded(value, minimum, maximum), do: value |> max(minimum) |> min(maximum)

  defp valid?(%{center_x: center_x, center_y: center_y, zoom: zoom})
       when is_number(center_x) and is_number(center_y) and zoom in @zooms do
    half_width = @width / zoom / 2
    half_height = @height / zoom / 2

    center_x >= half_width and center_x <= @width - half_width and
      center_y >= half_height and center_y <= @height - half_height
  end

  defp valid?(_), do: false

  defp format(value), do: :erlang.float_to_binary(value * 1.0, decimals: 2)
end
