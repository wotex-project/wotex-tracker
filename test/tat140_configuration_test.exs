defmodule Wotex.Tracker.TAT140ConfigurationTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Wotex.Tracker.Protocols.Teltonika.TAT140Configuration

  test "renders documented endpoint SMS commands and an honest USB manifest" do
    document = configuration()
    assert {:ok, config} = TAT140Configuration.new(document)

    assert TAT140Configuration.endpoint_sms_commands(config) == [
             "  setparam 2001:internet;2002:;2003:local-private-password",
             "  setparam 2004:tracker.example.test;2005:5001;2006:0"
           ]

    assert TAT140Configuration.endpoint_verification_sms(config) ==
             "  getparam 2001;2004;2005;2006"

    assert TAT140Configuration.endpoint_expectations(config) == %{
             "2001" => "internet",
             "2004" => "tracker.example.test",
             "2005" => 5001,
             "2006" => 0
           }

    assert %{
             "provisioning_path" => "teltonika_configurator_usb",
             "profile" => "teltonika.tat140.codec8e",
             "system" => %{"data_protocol" => "Codec 8 Extended"},
             "bluetooth" => %{
               "ble_feature" => "Sensors",
               "sensor_table" => [
                 %{
                   "slot" => 1,
                   "preset" => "EYE Sensor (Sensors)",
                   "mac" => "AA:BB:CC:DD:EE:FF",
                   "expected_avl_ids" => %{
                     "temperature" => 25,
                     "battery" => 29,
                     "humidity" => 86,
                     "movement_counter" => 463
                   }
                 }
               ]
             }
           } = TAT140Configuration.configurator_manifest(config)

    refute inspect(config) =~ document["cellular"]["password"]

    refute Enum.any?(
             TAT140Configuration.endpoint_sms_commands(config),
             &String.contains?(&1, "113:")
           )
  end

  test "a deterministic peer applies the ordered endpoint batch and read-back" do
    assert {:ok, config} = TAT140Configuration.new(configuration())

    peer =
      Enum.reduce(TAT140Configuration.endpoint_sms_commands(config), %{}, fn command, state ->
        apply_setparam(command, state)
      end)

    query = TAT140Configuration.endpoint_verification_sms(config)
    assert query == "  getparam 2001;2004;2005;2006"

    assert Map.take(peer, ~w(2001 2004 2005 2006)) == %{
             "2001" => "internet",
             "2004" => "tracker.example.test",
             "2005" => "5001",
             "2006" => "0"
           }
  end

  test "bounded closed configuration rejects command injection and unsupported paths" do
    valid = configuration()

    invalid = [
      %{},
      Map.put(valid, "schema", "wtr.tat140-configuration.v2"),
      Map.put(valid, "unknown", true),
      put_in(valid, ["provisioning_path"], "iphone_ble"),
      put_in(valid, ["sms", "login"], "login1"),
      valid |> put_in(["sms", "login"], "owner") |> put_in(["sms", "password"], ""),
      put_in(valid, ["cellular", "apn"], "apn;2004:attacker.invalid"),
      put_in(valid, ["cellular", "username"], "user name"),
      put_in(valid, ["cellular", "password"], "secret\ncpureset"),
      put_in(valid, ["cellular", "server"], "https://tracker.example.test"),
      put_in(valid, ["cellular", "port"], 0),
      put_in(valid, ["cellular", "transport"], "udp"),
      put_in(valid, ["protocol", "data"], "codec8"),
      put_in(valid, ["ble", "feature"], "backup_tracker"),
      put_in(valid, ["ble", "sensor"], "universal"),
      put_in(valid, ["ble", "slot"], 2),
      put_in(valid, ["ble", "mac"], "aa:bb:cc:dd:ee:ff"),
      put_in(valid, ["ble", "update_frequency_seconds"], 29),
      put_in(valid, ["ble", "lost_sensor_alarm"], "yes")
    ]

    for document <- invalid do
      assert {:error, :invalid_configuration} = TAT140Configuration.new(document)
    end
  end

  test "configured SMS credentials retain the exact documented command structure" do
    document =
      configuration()
      |> put_in(["sms"], %{"login" => "owner", "password" => "12345"})
      |> put_in(["cellular", "apn"], String.duplicate("a", 32))
      |> put_in(["cellular", "username"], String.duplicate("u", 32))
      |> put_in(["cellular", "password"], String.duplicate("p", 32))
      |> put_in(["cellular", "server"], String.duplicate("s", 55))

    assert {:ok, config} = TAT140Configuration.new(document)
    refute inspect(config) =~ "12345"

    for command <- TAT140Configuration.endpoint_sms_commands(config) do
      assert String.starts_with?(command, "owner 12345 setparam ")
      assert byte_size(command) <= 160
    end

    assert byte_size(TAT140Configuration.endpoint_verification_sms(config)) <= 160
  end

  defp configuration do
    %{
      "schema" => "wtr.tat140-configuration.v1",
      "provisioning_path" => "teltonika_configurator_usb",
      "sms" => %{"login" => "", "password" => ""},
      "cellular" => %{
        "apn" => "internet",
        "username" => "",
        "password" => "local-private-password",
        "server" => "tracker.example.test",
        "port" => 5001,
        "transport" => "tcp"
      },
      "protocol" => %{"data" => "codec8_extended"},
      "ble" => %{
        "feature" => "sensors",
        "sensor" => "eye_sensor",
        "slot" => 1,
        "mac" => "AA:BB:CC:DD:EE:FF",
        "update_frequency_seconds" => 120,
        "lost_sensor_alarm" => true
      }
    }
  end

  defp apply_setparam("  setparam " <> body, state) do
    body
    |> String.split(";", trim: true)
    |> Enum.reduce(state, fn pair, accumulator ->
      [id, value] = String.split(pair, ":", parts: 2)
      Map.put(accumulator, id, value)
    end)
  end
end
