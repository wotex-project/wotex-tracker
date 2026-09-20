previous = System.get_env("WOTEX_TRACKER_SOURCE_QUALIFIER_NO_MAIN")
System.put_env("WOTEX_TRACKER_SOURCE_QUALIFIER_NO_MAIN", "1")
Code.require_file("../scripts/qualify_source.exs", __DIR__)

if previous do
  System.put_env("WOTEX_TRACKER_SOURCE_QUALIFIER_NO_MAIN", previous)
else
  System.delete_env("WOTEX_TRACKER_SOURCE_QUALIFIER_NO_MAIN")
end

defmodule Wotex.Tracker.SourceQualifierTest do
  use ExUnit.Case, async: true

  alias Wotex.Tracker.SourceQualifier

  test "qualification children cannot inherit host composition" do
    environment = %{
      "HOME" => "/private/home",
      "MIX_BUILD_PATH" => "/ambient/build",
      "MIX_DEPS_PATH" => "/ambient/deps",
      "MIX_ENV" => "test",
      "WOTEX_PATH_DEPS" => "1",
      "WOTEX_TRACKER_APNS_CONFIG" => "/private/apns.json",
      "WOTEX_TRACKER_CELLULAR_CONFIG" => "/private/cellular.json",
      "WOTEX_TRACKER_CONFIG" => "/private/service.json",
      "WOTEX_TRACKER_FUTURE_COMPOSITION" => "enabled",
      "WOTEX_TRACKER_UI" => "1",
      "WOTEX_TRACKER_UI_CONFIG" => "/private/browser.json"
    }

    qualified = SourceQualifier.clean_environment(environment)

    assert qualified["HOME"] == "/private/home"
    assert qualified["MIX_ENV"] == "prod"

    for key <- [
          "MIX_BUILD_PATH",
          "MIX_DEPS_PATH",
          "WOTEX_PATH_DEPS",
          "WOTEX_TRACKER_APNS_CONFIG",
          "WOTEX_TRACKER_CELLULAR_CONFIG",
          "WOTEX_TRACKER_CONFIG",
          "WOTEX_TRACKER_FUTURE_COMPOSITION",
          "WOTEX_TRACKER_UI",
          "WOTEX_TRACKER_UI_CONFIG"
        ] do
      assert Map.fetch!(qualified, key) == nil
    end
  end
end
