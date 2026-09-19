%{
  name: :wotex_mobile_secure_store,
  mob_version: "~> 0.9.1",
  plugin_spec_version: 1,
  description: "Device-only iOS Keychain slots for the WoTEx mobile host",
  nifs: [
    %{
      module: :wotex_secure_store_nif,
      native_dir: "priv/native/ios",
      lang: :objc,
      platform: :ios
    }
  ],
  ios: %{frameworks: ["Security"]},
  host_requirements: [
    "The host must treat errSecInteractionNotAllowed as unavailable and never install a file fallback."
  ]
}
