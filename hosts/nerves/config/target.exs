import Config

cellular_config_path =
  case System.get_env("WOTEX_TRACKER_CELLULAR") do
    nil -> nil
    "1" -> "/root/tracker/cellular.json"
    _ -> raise "WOTEX_TRACKER_CELLULAR accepts only 1 when building cellular ingress"
  end

apns_config_path =
  case System.get_env("WOTEX_TRACKER_APNS") do
    nil -> nil
    "1" -> "/root/tracker/apns.json"
    _ -> raise "WOTEX_TRACKER_APNS accepts only 1 when building notification delivery"
  end

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
  cellular_config_path: cellular_config_path,
  apns_config_path: apns_config_path,
  browser_config_path:
    if(System.get_env("WOTEX_TRACKER_UI") == "1", do: "/root/tracker/browser.json", else: nil)
