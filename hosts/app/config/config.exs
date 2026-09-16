import Config
config :exqlite, force_build: true

if System.get_env("WOTEX_TRACKER_UI") == "1" do
  config :phoenix, :json_library, Jason
  config :phoenix, :filter_parameters, ["token", "password", "secret", "browser_session"]
  config :wotex_tracker_host, Wotex.Tracker.Host.Browser.Endpoint, []
end
