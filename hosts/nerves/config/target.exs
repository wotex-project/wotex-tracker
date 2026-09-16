import Config

config :logger, backends: [RingLogger]
config :shoehorn, init: [:nerves_runtime]
config :nerves_runtime, startup_guard_enabled: true
config :nerves, :erlinit, update_clock: true

config :vintage_net,
  config: [{"eth0", %{type: VintageNetEthernet, ipv4: %{method: :dhcp}}}]

config :nerves_time, time_file: "/data/nerves_time"

config :wotex_tracker_nerves,
  config_path: "/data/tracker/config.json",
  data_root: "/data/tracker",
  browser_config_path:
    if(System.get_env("WOTEX_TRACKER_UI") == "1", do: "/data/tracker/browser.json", else: nil)
