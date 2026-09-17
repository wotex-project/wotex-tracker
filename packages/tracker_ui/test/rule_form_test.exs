defmodule Wotex.Tracker.UI.RuleFormTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Wotex.Tracker.UI.RuleForm

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

    refute RuleForm.editable?("motion", %{})

    assert RuleForm.battery?(%{
             "properties" => %{"batteryVoltage" => %{"type" => "number", "unit" => "V"}}
           })

    refute RuleForm.battery?(%{
             "properties" => %{"batteryVoltage" => %{"type" => "number", "unit" => "mV"}}
           })
  end
end
