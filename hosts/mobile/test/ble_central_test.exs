defmodule Wotex.Tracker.Mobile.BLECentralTest do
  @moduledoc false

  use ExUnit.Case, async: true
  alias Wotex.Mobile.BLECentral
  alias Wotex.Tracker.Mobile.MobScreen

  @request "123e4567-e89b-42d3-a456-426614174000"
  @peripheral "123e4567-e89b-12d3-a456-426614174000"
  @service "180a"
  @characteristic "2a29"

  defmodule Native do
    for {function, arity} <- [
          scan: 3,
          stop_scan: 1,
          connect: 2,
          disconnect: 2,
          discover: 3,
          read: 4,
          write: 5
        ] do
      arguments = Macro.generate_arguments(arity, __MODULE__)

      def unquote(function)(unquote_splicing(arguments)) do
        send(self(), {:native_ble, unquote(function), [unquote_splicing(arguments)]})
        :ok
      end
    end
  end

  defmodule UnavailableNative do
    def scan(_, _, _), do: {:error, :powered_off}
  end

  defmodule FailingNative do
    def scan(_, _, _), do: raise("private native BLE failure")
  end

  defmodule WebView do
    def eval_js(socket, script) do
      send(self(), {:ble_script, script})
      Mob.Socket.assign(socket, :ble_delivered, true)
    end
  end

  defmodule InvalidWebView do
    def eval_js(_, _), do: :invalid
  end

  defmodule FailingWebView do
    def eval_js(_, _), do: throw(:private_webview_failure)
  end

  test "admits only the closed scan, connection, discovery, read and write commands" do
    socket = Mob.Socket.new(MobScreen)
    value = <<0, 1, 2, 255>>

    commands = [
      {command("scan", %{"service_uuids" => [@service], "timeout_ms" => 5_000}),
       {:scan, [@request, [@service], 5_000]}},
      {command("stop_scan"), {:stop_scan, [@request]}},
      {command("connect", %{"peripheral_id" => @peripheral}),
       {:connect, [@request, @peripheral]}},
      {command("disconnect", %{"peripheral_id" => @peripheral}),
       {:disconnect, [@request, @peripheral]}},
      {command("discover", %{"peripheral_id" => @peripheral, "service_uuids" => [@service]}),
       {:discover, [@request, @peripheral, [@service]]}},
      {command("read", characteristic_fields()),
       {:read, [@request, @peripheral, @service, @characteristic]}},
      {command(
         "write",
         Map.merge(characteristic_fields(), %{
           "encoding" => "base64url",
           "value" => Base.url_encode64(value, padding: false)
         })
       ), {:write, [@request, @peripheral, @service, @characteristic, value]}}
    ]

    for {request, {function, arguments}} <- commands do
      assert BLECentral.execute(socket, request, Native) == socket
      assert_received {:native_ble, ^function, ^arguments}
    end
  end

  test "rejects widened, ambiguous and oversized commands before native code" do
    socket = Mob.Socket.new(MobScreen)
    valid_scan = command("scan", %{"service_uuids" => [@service], "timeout_ms" => 5_000})

    valid_write =
      command(
        "write",
        Map.merge(characteristic_fields(), %{
          "encoding" => "base64url",
          "value" => Base.url_encode64("value", padding: false)
        })
      )

    invalid = [
      %{},
      Map.put(valid_scan, "extra", true),
      %{valid_scan | "schema" => "other"},
      %{valid_scan | "request_id" => String.upcase(@request)},
      %{valid_scan | "service_uuids" => []},
      %{valid_scan | "service_uuids" => ["180f", "180a"]},
      %{valid_scan | "service_uuids" => [@service, @service]},
      %{valid_scan | "service_uuids" => ["not-a-uuid"]},
      %{valid_scan | "timeout_ms" => 999},
      command("connect", %{"peripheral_id" => "private-address"}),
      command("read", %{characteristic_fields() | "service_uuid" => "180A"}),
      %{valid_write | "encoding" => "base64"},
      %{valid_write | "value" => "not+canonical"},
      %{
        valid_write
        | "value" => Base.url_encode64(String.duplicate("x", 513), padding: false)
      }
    ]

    for request <- invalid do
      assert BLECentral.execute(socket, request, Native) == socket
    end

    refute_received {:native_ble, _, _}
  end

  test "reports contained native failure under the originating request" do
    socket = Mob.Socket.new(MobScreen)
    scan = command("scan", %{"service_uuids" => [@service], "timeout_ms" => 5_000})

    assert BLECentral.execute(socket, scan, UnavailableNative) == socket
    assert_received {:ble_central, @request, :rejected, :powered_off}

    assert BLECentral.execute(socket, scan, FailingNative) == socket
    assert_received {:ble_central, @request, :rejected, :unavailable}
    assert BLECentral.execute(socket, scan, 42) == socket
  end

  test "delivers only bounded native event projections to the packaged page" do
    socket = Mob.Socket.new(MobScreen)

    events = [
      {:ble_central, @request, :scan_result, {@peripheral, "Tracker", -42, [@service]}},
      {:ble_central, @request, :scan_complete, nil},
      {:ble_central, @request, :scan_stopped, nil},
      {:ble_central, @request, :connected, @peripheral},
      {:ble_central, @request, :connect_failed, :unavailable},
      {:ble_central, @request, :disconnected, @peripheral},
      {:ble_central, @request, :services, {@peripheral, [@service]}},
      {:ble_central, @request, :characteristics,
       {@peripheral, @service, [{@characteristic, [:notify, :read]}]}},
      {:ble_central, @request, :discovery_complete, nil},
      {:ble_central, @request, :value, {@peripheral, @service, @characteristic, <<0, 255>>}},
      {:ble_central, @request, :written, {@peripheral, @service, @characteristic, ""}},
      {:ble_central, @request, :operation_failed, :not_connected},
      {:ble_central, @request, :rejected, :invalid_data},
      {:ble_central, @request, :rejected, :unauthorized}
    ]

    for event <- events do
      assert %{assigns: %{ble_delivered: true}} = BLECentral.deliver(socket, event, WebView)
      assert_received {:ble_script, script}
      assert script =~ "wotex:ble-central"
      assert script =~ "wtr.mobile-ble-central-event.v1"
      assert script =~ @request
    end
  end

  test "rejects malformed native events and contains WebView failures" do
    socket = Mob.Socket.new(MobScreen)
    valid = {:ble_central, @request, :connected, @peripheral}

    invalid = [
      {},
      {:ble_central, "bad-request", :connected, @peripheral},
      {:ble_central, @request, :connected, "bad-peripheral"},
      {:ble_central, @request, :scan_result, {@peripheral, nil, -128, [@service]}},
      {:ble_central, @request, :scan_result, {@peripheral, nil, -42, []}},
      {:ble_central, @request, :characteristics,
       {@peripheral, @service, [{@characteristic, [:read, :read]}]}},
      {:ble_central, @request, :value,
       {@peripheral, @service, @characteristic, String.duplicate("x", 513)}},
      {:ble_central, @request, :rejected, :private_reason}
    ]

    for event <- invalid do
      assert BLECentral.deliver(socket, event, WebView) == socket
    end

    assert BLECentral.deliver(socket, valid, InvalidWebView) == socket
    assert BLECentral.deliver(socket, valid, FailingWebView) == socket
    assert BLECentral.deliver(socket, valid, 42) == socket
    refute_received {:ble_script, _}
  end

  test "pins the app-owned CoreBluetooth plugin manifest and native bounds" do
    manifest_path = Application.app_dir(:wotex_mobile_ble, "priv/mob_plugin.exs")

    source_path =
      Application.app_dir(:wotex_mobile_ble, "priv/native/ios/wotex_ble_central_nif.m")

    {manifest, _} = Code.eval_file(manifest_path)
    source = File.read!(source_path)

    assert Application.get_env(:mob, :plugins) == [
             :mob_notify,
             :wotex_mobile_ble,
             :wotex_mobile_secure_store
           ]

    assert Application.get_env(:mob, :acknowledge_unsafe_plugins) == [
             :wotex_mobile_ble,
             :wotex_mobile_secure_store
           ]

    assert manifest.name == :wotex_mobile_ble
    assert manifest.mob_version == "~> 0.9.1"
    assert manifest.ios.frameworks == ["CoreBluetooth"]
    assert is_binary(manifest.ios.plist_keys["NSBluetoothAlwaysUsageDescription"])
    assert [%{module: :wotex_ble_central_nif, lang: :objc, platform: :ios}] = manifest.nifs

    for required <- [
          "CBCentralManagerScanOptionAllowDuplicatesKey : @NO",
          "WOTEX_MAX_SERVICES = 8",
          "WOTEX_MAX_PERIPHERALS = 64",
          "WOTEX_MAX_VALUE_BYTES = 512",
          "WOTEX_OPERATION_TIMEOUT_MS = 30000",
          "self.disconnections[identifier] ?: self.owners[identifier]",
          "CBCharacteristicWriteWithResponse"
        ] do
      assert source =~ required
    end

    refute source =~ "scanForPeripheralsWithServices:nil"
    refute source =~ "type:CBCharacteristicWriteWithoutResponse"
  end

  defp command(operation, fields \\ %{}) do
    Map.merge(
      %{
        "schema" => "wtr.mobile-ble-central-command.v1",
        "request_id" => @request,
        "operation" => operation
      },
      fields
    )
  end

  defp characteristic_fields do
    %{
      "peripheral_id" => @peripheral,
      "service_uuid" => @service,
      "characteristic_uuid" => @characteristic
    }
  end
end
