import Config

Application.start(:nerves_bootstrap)

if Mix.target() == :host do
  import_config "host.exs"
else
  import_config "target.exs"
end

if System.get_env("WOTEX_TRACKER_UI") == "1" do
  config :wotex_tracker_nerves, Wotex.Tracker.Nerves.Browser.Endpoint, []
end
