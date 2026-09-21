defmodule Wotex.Tracker.EYESensorConfigurationTest do
  use ExUnit.Case, async: true

  alias Wotex.Tracker.Protocols.Teltonika.EYESensorConfiguration, as: EYE

  @request "123e4567-e89b-42d3-a456-426614174001"
  @peripheral "123e4567-e89b-42d3-a456-426614174002"
  @service "e61c0000-7df2-4d4e-8e6d-c611745b92e9"
  @password "e61c0008-7df2-4d4e-8e6d-c611745b92e9"
  @command "e61c0007-7df2-4d4e-8e6d-c611745b92e9"
  @sensor_mask "e61c0021-7df2-4d4e-8e6d-c611745b92e9"

  test "builds only the documented scan, connection and discovery commands" do
    assert {:ok,
            %{
              "schema" => "wtr.mobile-ble-central-command.v1",
              "operation" => "scan",
              "request_id" => @request,
              "service_uuids" => [@service],
              "timeout_ms" => 10_000
            }} = EYE.scan_command(@request)

    assert {:ok, %{"operation" => "connect", "peripheral_id" => @peripheral}} =
             EYE.connect_command(@request, @peripheral)

    assert {:ok, %{"operation" => "disconnect", "peripheral_id" => @peripheral}} =
             EYE.disconnect_command(@request, @peripheral)

    assert {:ok, %{"operation" => "discover", "service_uuids" => [@service]}} =
             EYE.discover_command(@request, @peripheral)
  end

  test "encodes authentication, sensor activation, persistence and verification exactly" do
    assert {:ok,
            %{
              "operation" => "write",
              "characteristic_uuid" => @password,
              "encoding" => "base64url",
              "value" => "MTIzNDU2"
            }} = EYE.authenticate_command(@request, @peripheral, "123456")

    assert {:ok, %{mask: 15, sensors: [:temperature, :humidity, :magnetic, :movement]}} =
             EYE.decode_sensor_mask("Dw")

    assert {:ok, %{"characteristic_uuid" => @sensor_mask, "value" => "Dw"}} =
             EYE.sensor_mask_command(
               @request,
               @peripheral,
               [:temperature, :humidity, :magnetic, :movement]
             )

    assert {:ok, %{"characteristic_uuid" => @command, "value" => "ABA"}} =
             EYE.save_command(@request, @peripheral)

    assert {:ok, %{"operation" => "read", "characteristic_uuid" => @sensor_mask}} =
             EYE.read_sensor_mask_command(@request, @peripheral)
  end

  test "rejects unbounded, duplicate and undocumented command inputs" do
    for invalid <- ["12345", "12345x", "1234567", ""] do
      assert {:error, :invalid_command} =
               EYE.authenticate_command(@request, @peripheral, invalid)
    end

    assert {:error, :invalid_command} = EYE.scan_command(@request, 999)
    assert {:error, :invalid_command} = EYE.scan_command(@request, 30_001)
    assert {:error, :invalid_command} = EYE.connect_command("bad", @peripheral)
    assert {:error, :invalid_command} = EYE.connect_command(@request, "private-address")
    assert {:error, :invalid_command} = EYE.disconnect_command(@request, nil)
    assert {:error, :invalid_command} = EYE.discover_command(@request, "bad")
    assert {:error, :invalid_command} = EYE.read_sensor_mask_command(@request, "bad")
    assert {:error, :invalid_command} = EYE.sensor_mask_command(@request, @peripheral, :all)
    assert {:error, :invalid_sensor_mask} = EYE.sensor_mask([:temperature, :temperature])
    assert {:error, :invalid_sensor_mask} = EYE.sensor_mask([:location])
    assert {:error, :invalid_sensor_mask} = EYE.sensor_mask(:all)
    assert {:error, :invalid_value} = EYE.decode_sensor_mask("EA")
    assert {:error, :invalid_value} = EYE.decode_sensor_mask(15)
  end

  test "accepts only strict target events from the generic native bridge" do
    valid = %{
      "schema" => "wtr.mobile-ble-central-event.v1",
      "request_id" => @request,
      "event" => "scan_result",
      "data" => %{
        "peripheral_id" => @peripheral,
        "name" => "EYE_1234567",
        "rssi" => -42,
        "service_uuids" => [@service]
      }
    }

    assert {:ok, %{"event" => "scan_result"}} = EYE.decode_event(valid)

    characteristics = %{
      "schema" => "wtr.mobile-ble-central-event.v1",
      "request_id" => @request,
      "event" => "characteristics",
      "data" => %{
        "peripheral_id" => @peripheral,
        "service_uuid" => @service,
        "characteristics" => [
          %{"uuid" => @command, "properties" => ["write"]},
          %{"uuid" => @password, "properties" => ["write"]},
          %{"uuid" => @sensor_mask, "properties" => ["read", "write"]}
        ]
      }
    }

    assert {:ok, %{"event" => "characteristics"}} = EYE.decode_event(characteristics)

    for invalid <- [
          Map.put(valid, "extra", true),
          put_in(valid, ["data", "service_uuids"], ["180a"]),
          put_in(valid, ["data", "rssi"], -128),
          put_in(valid, ["request_id"], "bad"),
          put_in(characteristics, ["data", "characteristics", Access.at(0), "uuid"], "zzzz"),
          %{}
        ] do
      assert {:error, :invalid_event} = EYE.decode_event(invalid)
    end
  end

  test "admits every closed lifecycle, failure and value event" do
    for {event, data} <- [
          {"rejected", %{"reason" => "powered_off"}},
          {"connect_failed", %{"reason" => "not_found"}},
          {"operation_failed", %{"reason" => "not_connected"}},
          {"connected", %{"peripheral_id" => @peripheral}},
          {"disconnected", %{"peripheral_id" => @peripheral}},
          {"scan_complete", %{}},
          {"scan_stopped", %{}},
          {"discovery_complete", %{}},
          {"services", %{"peripheral_id" => @peripheral, "service_uuids" => [@service]}},
          {"value",
           %{
             "peripheral_id" => @peripheral,
             "service_uuid" => @service,
             "characteristic_uuid" => @sensor_mask,
             "value" => "Dw"
           }},
          {"written",
           %{
             "peripheral_id" => @peripheral,
             "service_uuid" => @service,
             "characteristic_uuid" => @command
           }}
        ] do
      envelope = %{
        "schema" => "wtr.mobile-ble-central-event.v1",
        "request_id" => @request,
        "event" => event,
        "data" => data
      }

      assert {:ok, %{"event" => ^event, "data" => ^data}} = EYE.decode_event(envelope)
    end
  end

  test "rejects widened lifecycle, characteristic and value events" do
    required = [
      %{"uuid" => @command, "properties" => ["write"]},
      %{"uuid" => @password, "properties" => ["write"]},
      %{"uuid" => @sensor_mask, "properties" => ["read", "write"]}
    ]

    event = fn kind, data ->
      %{
        "schema" => "wtr.mobile-ble-central-event.v1",
        "request_id" => @request,
        "event" => kind,
        "data" => data
      }
    end

    characteristic_event = fn characteristics ->
      event.("characteristics", %{
        "peripheral_id" => @peripheral,
        "service_uuid" => @service,
        "characteristics" => characteristics
      })
    end

    assert {:ok, %{"event" => "characteristics"}} =
             EYE.decode_event(characteristic_event.(tl(required)))

    for invalid <- [
          event.("rejected", %{"reason" => "arbitrary"}),
          event.("connected", %{"peripheral_id" => "bad"}),
          event.("scan_complete", %{"extra" => true}),
          event.("services", %{"peripheral_id" => @peripheral, "service_uuids" => ["180a"]}),
          characteristic_event.([]),
          characteristic_event.([hd(required) | required]),
          characteristic_event.([
            %{"uuid" => @command, "properties" => ["write", "read"]} | tl(required)
          ]),
          characteristic_event.([
            %{"uuid" => @command, "properties" => ["execute"]} | tl(required)
          ]),
          characteristic_event.([
            %{"uuid" => @command, "properties" => ["write"], "extra" => true}
            | tl(required)
          ]),
          event.("value", %{
            "peripheral_id" => @peripheral,
            "service_uuid" => @service,
            "characteristic_uuid" => @sensor_mask,
            "value" => "***"
          }),
          event.("value", %{
            "peripheral_id" => @peripheral,
            "service_uuid" => @service,
            "characteristic_uuid" => @sensor_mask,
            "value" => Base.url_encode64(String.duplicate("x", 513), padding: false)
          }),
          event.("written", %{
            "peripheral_id" => @peripheral,
            "service_uuid" => @service,
            "characteristic_uuid" => "2a29"
          }),
          event.("unknown", %{})
        ] do
      assert {:error, :invalid_event} = EYE.decode_event(invalid)
    end
  end
end
