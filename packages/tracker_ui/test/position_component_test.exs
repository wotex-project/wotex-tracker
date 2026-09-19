defmodule Wotex.Tracker.UI.PositionComponentTest do
  @moduledoc false
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  alias Wotex.Tracker.UI.{Components, Presenter}

  test "renders retained qualified position claims without implying fusion or liveness" do
    state = %{
      "observed_at" => scalar(1_700_000_000_000),
      "positions" => [
        position(),
        %{
          position()
          | "source" => "cellular",
            "availability" => "unavailable",
            "quality" => "unavailable",
            "latitude" => scalar(nil),
            "longitude" => scalar(nil),
            "horizontal_accuracy_m" => scalar(nil),
            "accuracy_kind" => "unknown",
            "fix_at" => scalar(nil),
            "fix_clock" => "unknown"
        }
      ]
    }

    html = render_component(&Components.positions/1, %{state: state})
    assert html =~ "GNSS: 59.3293, 18.0686"
    assert html =~ "bound accuracy 5.0 m"
    assert html =~ "Cellular position unavailable"
    assert html =~ "not a live or fused location"
    assert html =~ "does not choose a canonical position or infer a route"
    refute html =~ "private-position-source"
  end

  test "empty and malformed values remain explicit rather than becoming zero coordinates" do
    html =
      render_component(&Components.positions/1, %{
        state: %{"observed_at" => scalar(0), "positions" => []}
      })

    assert html =~ "No position was supplied by this profile."
    refute html =~ "0, 0"
    assert Presenter.position_summary(%{}) == "Position unavailable"
    assert Presenter.position_accuracy(%{}) == "accuracy unknown"
    assert Presenter.position_source("future-source") == "Unknown source"
  end

  test "offline projection status states age, completeness and access expiry" do
    html =
      render_component(&Components.offline_status/1, %{
        projection: %{
          "_offline" => %{
            "source" => "offline_cache",
            "synchronized_at" => 1_700_000_000_000,
            "age_ms" => 65_000,
            "complete" => false,
            "expires_at" => 1_700_003_600_000
          }
        }
      })

    assert html =~ "Offline cached data"
    assert html =~ "65000 ms"
    assert html =~ "more remote pages may exist"
    assert html =~ "Cached access expires"
    assert render_component(&Components.offline_status/1, %{projection: %{}}) == ""
  end

  defp position,
    do: %{
      "schema" => "wtr.position-public.v1",
      "latitude" => scalar(59.3293),
      "longitude" => scalar(18.0686),
      "altitude_m" => scalar(nil),
      "speed_m_s" => scalar(0.0),
      "horizontal_accuracy_m" => scalar(5.0),
      "accuracy_kind" => "bound",
      "source" => "gnss",
      "fix_at" => scalar(1_700_000_000_000),
      "received_at" => scalar(1_700_000_000_000),
      "fix_clock" => "trusted",
      "availability" => "available",
      "quality" => "valid"
    }

  defp scalar(value) do
    type =
      cond do
        is_nil(value) -> "null"
        is_integer(value) -> "integer"
        is_float(value) -> "number"
      end

    %{"type" => type, "value" => value}
  end
end
