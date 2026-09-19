defmodule Wotex.Tracker.UI.RuleFormTest do
  @moduledoc false
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  alias Wotex.Tracker.UI.{Presenter, RuleForm}

  test "fields convert to closed parameters without inventing values" do
    assert {:ok, %{"maximum_silence_ms" => 60_000, "future_skew_ms" => 0}} =
             RuleForm.parameters("heartbeat", %{
               "maximum_silence_seconds" => "60",
               "future_skew_seconds" => "0"
             })

    assert {:ok, %{"low_threshold" => 2.5, "clear_threshold" => 2.8, "accept_suspect" => true}} =
             RuleForm.parameters("battery", %{
               "low_threshold" => "2.5",
               "clear_threshold" => "2.8",
               "maximum_age_seconds" => "3600",
               "future_skew_seconds" => "5",
               "accept_suspect" => "true"
             })

    assert {:ok,
            %{
              "event_time" => "trusted_fix",
              "future_skew_ms" => 1_000,
              "late_window_ms" => 10_000,
              "sequence" => "none",
              "uncertainty" => "require_bound",
              "moving_speed_m_s" => 1,
              "stationary_speed_m_s" => 0.1,
              "moving_distance_m" => 5,
              "stationary_distance_m" => 1,
              "max_plausible_speed_m_s" => 100,
              "max_gap_ms" => 300_000,
              "minimum_movement_ms" => 30_000,
              "minimum_stop_ms" => 60_000
            }} =
             RuleForm.parameters("motion", %{
               "event_time" => "trusted_fix",
               "future_skew_seconds" => "1",
               "late_window_seconds" => "10",
               "sequence" => "none",
               "uncertainty" => "require_bound",
               "moving_speed_m_s" => "1",
               "stationary_speed_m_s" => "0.1",
               "moving_distance_m" => "5",
               "stationary_distance_m" => "1",
               "max_plausible_speed_m_s" => "100",
               "max_gap_seconds" => "300",
               "minimum_movement_seconds" => "30",
               "minimum_stop_seconds" => "60"
             })

    assert {:ok,
            %{
              "shape" => %{
                "kind" => "circle",
                "latitude" => 59.3293,
                "longitude" => 18.0686,
                "radius_m" => 100
              },
              "boundary" => "inside",
              "uncertainty" => "coordinate_only",
              "event_time" => "trusted_fix_or_receiver",
              "sequence" => "optional",
              "max_transition_gap_ms" => 120_000
            }} =
             RuleForm.parameters("geofence", %{
               "shape_kind" => "circle",
               "latitude" => "59.3293",
               "longitude" => "18.0686",
               "radius_m" => "100",
               "boundary" => "inside",
               "uncertainty" => "coordinate_only",
               "event_time" => "trusted_fix_or_receiver",
               "future_skew_seconds" => "0",
               "late_window_seconds" => "300",
               "sequence" => "optional",
               "max_transition_gap_seconds" => "120"
             })

    assert {:ok, %{"shape" => %{"kind" => "polygon", "vertices" => vertices}}} =
             RuleForm.parameters("geofence", %{
               "shape_kind" => "polygon",
               "vertices" => "59.32,18.05\n59.32,18.09\n59.35,18.07\n",
               "boundary" => "outside",
               "uncertainty" => "require_bound",
               "event_time" => "trusted_fix",
               "future_skew_seconds" => "0",
               "late_window_seconds" => "0",
               "sequence" => "required",
               "max_transition_gap_seconds" => "0"
             })

    assert length(vertices) == 3

    for input <- [
          {"heartbeat", %{"maximum_silence_seconds" => "-1", "future_skew_seconds" => "0"}},
          {"battery", %{"low_threshold" => "0", "clear_threshold" => "2.8"}},
          {"battery",
           %{
             "low_threshold" => "2.5",
             "clear_threshold" => "2.8",
             "maximum_age_seconds" => "1",
             "future_skew_seconds" => "0",
             "accept_suspect" => "yes"
           }},
          {"motion", %{}},
          {"motion",
           motion_input(%{
             "stationary_speed_m_s" => "2",
             "moving_speed_m_s" => "1"
           })},
          {"motion", motion_input(%{"moving_speed_m_s" => "fast"})},
          {"motion", motion_input(%{"minimum_movement_seconds" => "0"})},
          {"geofence", geofence_input(%{"latitude" => "91"})},
          {"geofence", geofence_input(%{"shape_kind" => "polygon", "vertices" => "0,0\n1,1"})},
          {"geofence",
           geofence_input(%{"shape_kind" => "polygon", "vertices" => "0,0\n1,1\nbad"})},
          {"geofence",
           geofence_input(%{"shape_kind" => "polygon", "vertices" => "0,0\n1,1\nx,2"})},
          {"geofence", geofence_input(%{"boundary" => "edge"})},
          {"heartbeat", nil}
        ] do
      assert :error == RuleForm.parameters(elem(input, 0), elem(input, 1))
    end
  end

  test "only whole-second voltage rules round-trip through the browser fields" do
    assert RuleForm.editable?("heartbeat", %{"maximum_silence_ms" => 1_000, "future_skew_ms" => 0})

    refute RuleForm.editable?("heartbeat", %{"maximum_silence_ms" => 1_500, "future_skew_ms" => 0})

    refute RuleForm.editable?("battery", %{
             "measurement_kind" => "humidity",
             "unit" => "%",
             "maximum_age_ms" => 1_000,
             "future_skew_ms" => 0
           })

    assert RuleForm.editable?("motion", motion_parameters())
    refute RuleForm.editable?("motion", Map.put(motion_parameters(), "max_gap_ms", 1_500))

    assert RuleForm.editable?("geofence", geofence_parameters())
    refute RuleForm.editable?("geofence", put_in(geofence_parameters(), ["shape", "extra"], 1))

    assert RuleForm.battery?(%{
             "properties" => %{"batteryVoltage" => %{"type" => "number", "unit" => "V"}}
           })

    refute RuleForm.battery?(%{
             "properties" => %{"batteryVoltage" => %{"type" => "number", "unit" => "mV"}}
           })
  end

  test "position-rule fields retain exact stored values" do
    html =
      render_component(&RuleForm.fields/1,
        kinds: ["motion"],
        parameters: motion_parameters()
      )

    assert html =~ ~s(id="rule-moving-speed")
    assert html =~ ~s(value="1.0")
    assert html =~ ~s(id="rule-event-time")
    refute html =~ ~s(id="rule-latitude")

    polygon =
      geofence_parameters()
      |> Map.put("shape", %{
        "kind" => "polygon",
        "vertices" => [
          %{"latitude" => 1, "longitude" => 2},
          %{"latitude" => 3, "longitude" => 4},
          %{"latitude" => 5, "longitude" => 6}
        ]
      })

    html =
      render_component(&RuleForm.fields/1,
        kinds: ["geofence"],
        parameters: polygon
      )

    assert html =~ "1,2\n3,4\n5,6"
    assert html =~ ~s(option value="polygon" selected)
    assert html =~ ~s(id="rule-transition-gap")
  end

  test "position-rule summaries distinguish geometry without exposing evidence" do
    assert Presenter.rule_parameters("motion", motion_parameters()) =~ "Moving ≥ 1.0 m/s"

    assert Presenter.rule_parameters("geofence", geofence_parameters()) ==
             "Circle at 59.3293, 18.0686 · radius 100.0 m · transition gap 300000 ms"

    polygon =
      geofence_parameters()
      |> Map.put("shape", %{
        "kind" => "polygon",
        "vertices" => [%{}, %{}, %{}]
      })

    assert Presenter.rule_parameters("geofence", polygon) ==
             "Polygon · 3 vertices · transition gap 300000 ms"

    assert Presenter.rule_parameters("geofence", %{
             "shape" => %{},
             "max_transition_gap_ms" => 0
           }) == "Fence geometry unavailable · transition gap 0 ms"
  end

  defp motion_input(changes) do
    Map.merge(
      %{
        "event_time" => "trusted_fix",
        "future_skew_seconds" => "0",
        "late_window_seconds" => "10",
        "sequence" => "none",
        "uncertainty" => "require_bound",
        "moving_speed_m_s" => "1",
        "stationary_speed_m_s" => "0.1",
        "moving_distance_m" => "5",
        "stationary_distance_m" => "1",
        "max_plausible_speed_m_s" => "100",
        "max_gap_seconds" => "300",
        "minimum_movement_seconds" => "30",
        "minimum_stop_seconds" => "60"
      },
      changes
    )
  end

  defp geofence_input(changes) do
    Map.merge(
      %{
        "shape_kind" => "circle",
        "latitude" => "59.3293",
        "longitude" => "18.0686",
        "radius_m" => "100",
        "boundary" => "inside",
        "uncertainty" => "require_bound",
        "event_time" => "trusted_fix",
        "future_skew_seconds" => "0",
        "late_window_seconds" => "10",
        "sequence" => "none",
        "max_transition_gap_seconds" => "300"
      },
      changes
    )
  end

  defp motion_parameters,
    do: %{
      "event_time" => "trusted_fix",
      "future_skew_ms" => 0,
      "late_window_ms" => 10_000,
      "sequence" => "none",
      "moving_speed_m_s" => 1.0,
      "stationary_speed_m_s" => 0.1,
      "moving_distance_m" => 5.0,
      "stationary_distance_m" => 1.0,
      "max_plausible_speed_m_s" => 100.0,
      "max_gap_ms" => 300_000,
      "uncertainty" => "require_bound",
      "minimum_movement_ms" => 30_000,
      "minimum_stop_ms" => 60_000
    }

  defp geofence_parameters,
    do: %{
      "shape" => %{
        "kind" => "circle",
        "latitude" => 59.3293,
        "longitude" => 18.0686,
        "radius_m" => 100.0
      },
      "boundary" => "inside",
      "uncertainty" => "coordinate_only",
      "event_time" => "trusted_fix",
      "future_skew_ms" => 0,
      "late_window_ms" => 10_000,
      "sequence" => "none",
      "max_transition_gap_ms" => 300_000
    }
end
