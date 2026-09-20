import Config

config :logger,
  backends: if(Mix.target() == :qemu_aarch64, do: [RingLogger, :console], else: [RingLogger])

config :shoehorn, init: [:nerves_runtime]
config :nerves_runtime, startup_guard_enabled: true
config :nerves, :erlinit, update_clock: true

config :vintage_net,
  config: [{"eth0", %{type: VintageNetEthernet, ipv4: %{method: :dhcp}}}]

config :nerves_time, time_file: "/data/nerves_time"

config :wotex_tracker_nerves,
  config_path: "/root/tracker/config.json",
  data_root: "/root/tracker",
  cellular_config_path:
    if(System.get_env("WOTEX_TRACKER_CELLULAR") == "1",
      do: "/root/tracker/cellular.json",
      else: nil
    ),
  browser_config_path:
    if(System.get_env("WOTEX_TRACKER_UI") == "1", do: "/root/tracker/browser.json", else: nil)
