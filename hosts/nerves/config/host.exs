import Config

# Tests explicitly provide a private configuration directory. Nothing listens
# merely because the Mix project is loaded on a development computer.
config :wotex_tracker_nerves, config_path: nil, data_root: nil, browser_config_path: nil
