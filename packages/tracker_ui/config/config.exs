import Config
config :exqlite, force_build: true
config :phoenix, :json_library, Jason
config :phoenix, :filter_parameters, ["token", "password", "secret", "browser_session"]
