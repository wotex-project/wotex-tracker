%{
  name: :wotex_mobile_ble,
  mob_version: "~> 0.9.1",
  plugin_spec_version: 1,
  description: "Bounded iOS CoreBluetooth central primitives for local tracker provisioning",
  nifs: [
    %{
      module: :wotex_ble_central_nif,
      native_dir: "priv/native/ios",
      lang: :objc,
      platform: :ios
    }
  ],
  ios: %{
    frameworks: ["CoreBluetooth"],
    plist_keys: %{
      "NSBluetoothAlwaysUsageDescription" =>
        "WoTEx uses Bluetooth to provision trackers you explicitly select nearby."
    }
  },
  host_requirements: [
    "Bluetooth central acceptance requires a signed physical-iPhone build and an explicitly qualified target service/characteristic profile."
  ]
}
