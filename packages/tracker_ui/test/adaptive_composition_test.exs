defmodule Wotex.Tracker.UI.AdaptiveCompositionTest do
  @moduledoc false
  use ExUnit.Case, async: true

  @css Path.expand("../priv/static/tracker.css", __DIR__)

  test "shared task surfaces use the documented content profiles" do
    css = File.read!(@css)

    assert css =~ "container-name: task-surface"
    assert css =~ "container-type: inline-size"
    assert css =~ "@container task-surface (max-width: 599px)"
    assert css =~ "@container task-surface (min-width: 600px)"
    assert css =~ "@container task-surface (min-width: 840px)"
  end

  test "task composition no longer depends on the narrow viewport query" do
    css = File.read!(@css)
    [_, viewport_rules] = String.split(css, "@media (max-width: 600px)", parts: 2)

    refute viewport_rules =~ ".heading"
    refute viewport_rules =~ ".operation"
    refute viewport_rules =~ ".tracker-map"
  end
end
