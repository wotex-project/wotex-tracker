ExUnit.start()
{:ok, _} = Application.ensure_all_started(:wotex_tracker_service)

if System.get_env("WOTEX_TRACKER_UI") == "1" do
  {:ok, _} = Application.ensure_all_started(:wotex_tracker_ui)
end
