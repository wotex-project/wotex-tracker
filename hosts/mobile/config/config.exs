import Config

config :exqlite, force_build: true
config :mob, :plugins, [:mob_notify, :wotex_mobile_secure_store]
config :mob, :acknowledge_unsafe_plugins, [:wotex_mobile_secure_store]
config :phoenix, :json_library, Jason
config :phoenix, :filter_parameters, ["token", "password", "secret", "credential"]
