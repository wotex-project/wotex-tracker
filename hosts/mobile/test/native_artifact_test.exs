defmodule Wotex.Tracker.Mobile.NativeArtifactTest do
  @moduledoc false

  use ExUnit.Case, async: true

  @root Path.expand("..", __DIR__)

  test "committed iOS launcher boots the exact mobile entry without background keepalive" do
    delegate = read!("ios/AppDelegate.m")
    plist = read!("ios/Info.plist")
    beam = read!("ios/beam_main.m")
    bootstrap = read!("src/wotex_tracker_mobile.erl")

    assert delegate =~ "didFinishLaunchingWithOptions"
    assert delegate =~ "scene:willConnectToSession"
    assert delegate =~ "didRegisterForRemoteNotificationsWithDeviceToken"
    assert delegate =~ "mob_send_push_token"
    assert delegate =~ "mob_boot_runtime"
    assert beam =~ ~s(#define APP_MODULE "wotex_tracker_mobile")
    assert bootstrap =~ "'Elixir.Wotex.Tracker.Mobile.MobApp':start()"

    assert plist =~ "<string>org.wotex.tracker</string>"
    assert plist =~ "<string>WoTEx Tracker</string>"
    refute plist =~ "UIBackgroundModes"
    refute plist =~ "NSMicrophoneUsageDescription"
    refute plist =~ "com.example"
  end

  test "native build configuration activates only the bounded application plugins" do
    config = read!("mob.exs.example")
    ble = read!("plugins/wotex_mobile_ble/priv/mob_plugin.exs")
    secure_store = read!("plugins/wotex_mobile_secure_store/priv/mob_plugin.exs")
    driver_table = read!("priv/generated/driver_tab_ios.c")

    assert config =~ ~s(platforms: [:ios])
    assert config =~ ~s(ios_bundle_id: "org.wotex.tracker")

    assert config =~
             "config :mob, :plugins, [:mob_notify, :wotex_mobile_ble, :wotex_mobile_secure_store]"

    assert config =~ "ed25519:Fdps1S9I5/BFuCIS6WOpQ0s7Rf98zvsc04wWy4+IqIE="
    assert config =~ ":wotex_mobile_ble"
    assert config =~ ":wotex_mobile_secure_store"

    assert ble =~ ~s("CoreBluetooth")
    assert ble =~ ~s("NSBluetoothAlwaysUsageDescription")
    assert secure_store =~ ~s("Security")

    for entry <- [
          "mob_notify_nif_nif_init",
          "wotex_ble_central_nif_nif_init",
          "wotex_secure_store_nif_nif_init"
        ] do
      assert driver_table =~ entry
    end

    for build <- ["ios/build.zig", "ios/build_device.zig"] do
      source = read!(build)
      assert source =~ "plugin_swift_files"
      assert source =~ "plugin_frameworks"
      assert source =~ "plugin_c_nifs"
    end
  end

  test "APNs signing templates keep development and production explicit" do
    development = read!("ios/WotexTrackerMobile.development.entitlements.example")
    production = read!("ios/WotexTrackerMobile.production.entitlements.example")

    assert development =~ "<key>aps-environment</key>"
    assert development =~ "<string>development</string>"
    refute development =~ "<string>production</string>"

    assert production =~ "<key>aps-environment</key>"
    assert production =~ "<string>production</string>"
    refute production =~ "<string>development</string>"

    wrapper = read!("scripts/release_ios.exs")
    finalizer = read!("scripts/ios_release.exs")
    assert wrapper =~ "MobDev.Release.build_ipa"
    assert wrapper =~ "IOSRelease.finalize"
    assert finalizer =~ ~s(@codesign "/usr/bin/codesign")
    assert finalizer =~ ~s("aps-environment" => profile.environment)
    refute finalizer =~ "System.shell"
    refute finalizer =~ ":os.cmd"
  end

  test "native generated output and local Mob configuration stay ignored" do
    ignore = read!(".gitignore")

    for entry <- [
          "/mob.exs",
          "/.mob/",
          "/ios/build/",
          "/ios/DerivedData/",
          "/ios/.zig-cache/",
          "/ios/zig-out/",
          "/ios/*.entitlements",
          "/ios/release_device.sh",
          "/_build/mob_release/",
          "/priv/generated/driver_tab_android.c"
        ] do
      assert ignore =~ entry
    end
  end

  defp read!(path), do: File.read!(Path.join(@root, path))
end
