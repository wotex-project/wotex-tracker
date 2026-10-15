# Portable native build configuration. Machine paths and signing values belong in mob.local.exs.
import Config

config :mob_dev,
  mob_dir: Path.join(File.cwd!(), "deps/mob"),
  elixir_lib:
    System.get_env("MOB_ELIXIR_LIB") ||
      :code.lib_dir(:elixir) |> to_string() |> Path.dirname(),
  platforms: [:ios],
  ios_bundle_id: "org.wotex.tracker"

config :mob, :plugins, [:mob_notify, :wotex_mobile_ble, :wotex_mobile_secure_store]

config :mob, :trusted_plugins, %{
  mob_notify: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg="
}

# These plugins are repository-owned and unsigned. The native gate still
# validates their closed manifests and requires this explicit acknowledgement.
config :mob, :acknowledge_unsafe_plugins, [
  :wotex_mobile_ble,
  :wotex_mobile_secure_store
]

if File.exists?(Path.join(__DIR__, "mob.local.exs")) do
  import_config("mob.local.exs")
end
