import Config

config :exqlite, force_build: true
config :mob, :plugins, [:mob_notify, :wotex_mobile_ble, :wotex_mobile_secure_store]
config :mob, :acknowledge_unsafe_plugins, [:wotex_mobile_ble, :wotex_mobile_secure_store]
config :phoenix, :json_library, Jason
config :phoenix, :filter_parameters, ["token", "password", "secret", "credential"]

case System.get_env("WOTEX_NOTIFICATION_ENVIRONMENT") do
  nil ->
    :ok

  environment when environment in ["sandbox", "production"] ->
    config :wotex_tracker_mobile, :notification_environment, environment

  _ ->
    raise "WOTEX_NOTIFICATION_ENVIRONMENT must be sandbox or production"
end
