defmodule Wotex.Tracker.UI.RouteViewportTest do
  use ExUnit.Case, async: true
  alias Wotex.Tracker.UI.RouteViewport

  test "zoom and pan stay inside the evidence-map extent" do
    viewport = RouteViewport.new()
    assert RouteViewport.view_box(viewport) == "0.00 0.00 1000.00 400.00"
    assert RouteViewport.label(viewport) == "Map zoom 1×"

    {:ok, viewport} = RouteViewport.update(viewport, "zoom-in")
    assert RouteViewport.view_box(viewport) == "250.00 100.00 500.00 200.00"

    {:ok, viewport} = RouteViewport.update(viewport, "pan-right")
    assert RouteViewport.view_box(viewport) == "375.00 100.00 500.00 200.00"

    {:ok, viewport} = RouteViewport.update(viewport, "pan-left")
    {:ok, viewport} = RouteViewport.update(viewport, "pan-up")
    assert RouteViewport.view_box(viewport) == "250.00 50.00 500.00 200.00"

    {:ok, viewport} = RouteViewport.update(viewport, "pan-down")
    assert RouteViewport.view_box(viewport) == "250.00 100.00 500.00 200.00"

    {:ok, viewport} = RouteViewport.update(viewport, "zoom-out")
    assert RouteViewport.view_box(viewport) == "0.00 0.00 1000.00 400.00"

    {:ok, viewport} = RouteViewport.update(viewport, "zoom-in")

    viewport =
      Enum.reduce(1..20, viewport, fn _, current ->
        {:ok, next} = RouteViewport.update(current, "pan-right")
        next
      end)

    assert RouteViewport.view_box(viewport) == "500.00 100.00 500.00 200.00"

    {:ok, viewport} = RouteViewport.update(viewport, "reset")
    assert RouteViewport.view_box(viewport) == "0.00 0.00 1000.00 400.00"
  end

  test "commands and zoom limits are closed" do
    viewport = RouteViewport.new()
    assert {:ok, ^viewport} = RouteViewport.update(viewport, "zoom-out")
    assert :error = RouteViewport.update(viewport, "invent")
    assert :error = RouteViewport.update(%{}, "pan-left")
    assert :error = RouteViewport.update(%{zoom: 2}, "pan-left")

    assert :error =
             RouteViewport.update(%{center_x: -1.0, center_y: 200.0, zoom: 2}, "reset")

    viewport =
      Enum.reduce(1..3, viewport, fn _, current ->
        {:ok, next} = RouteViewport.update(current, "zoom-in")
        next
      end)

    assert RouteViewport.label(viewport) == "Map zoom 8×"
    assert {:ok, ^viewport} = RouteViewport.update(viewport, "zoom-in")
  end
end
