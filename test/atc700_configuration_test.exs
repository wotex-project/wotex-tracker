defmodule Wotex.Tracker.ATC700ConfigurationTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Wotex.Tracker.Protocols.Teltonika.ATC700Configuration

  test "renders password-only SMS, read-back and a reviewable ATC700 TCT manifest" do
    document = configuration()
    assert {:ok, config} = ATC700Configuration.new(document)

    assert ATC700Configuration.endpoint_sms_commands(config) == [
             "12345 setparam 2025:0;2001:internet;2002:subscriber;2003:private",
             "12345 setparam 2004:tracker.example.test;2005:5027;2006:0",
             "12345 setparam 1004:1;113:0"
           ]

    assert ATC700Configuration.endpoint_verification_sms(config) ==
             "12345 getparam 2025;2001;2004;2005;2006;1004;113"

    assert ATC700Configuration.endpoint_expectations(config) == %{
             "113" => 0,
             "1004" => 1,
             "2001" => "internet",
             "2004" => "tracker.example.test",
             "2005" => 5027,
             "2006" => 0,
             "2025" => 0
           }

    assert %{
             "schema" => "wtr.atc700-tct-manifest.v1",
             "profile" => "teltonika.atc700.codec8e",
             "sms_call" => %{
               "sms_security" => %{
                 "authentication" => "Password only",
                 "password" => "12345"
               }
             },
             "mobile_network" => %{
               "mobile_data" => %{
                 "auto_apn" => "Disabled",
                 "apn" => "internet",
                 "apn_username" => "subscriber",
                 "apn_password" => "private"
               },
               "primary_server" => %{
                 "domain" => "tracker.example.test",
                 "port" => 5027,
                 "data_protocol" => "TCP"
               }
             },
             "tracking" => %{
               "records" => %{
                 "data_protocol" => "Codec 8 Extended",
                 "server_confirmation_method" => "AVL"
               }
             }
           } = ATC700Configuration.configurator_manifest(config)

    refute inspect(config) =~ "12345"
    refute inspect(config) =~ "private"
  end

  test "an unset password retains the documented leading-space command syntax" do
    document = put_in(configuration(), ["sms", "password"], "")
    assert {:ok, config} = ATC700Configuration.new(document)

    for command <-
          ATC700Configuration.endpoint_sms_commands(config) ++
            [ATC700Configuration.endpoint_verification_sms(config)] do
      assert String.starts_with?(command, " ")
      refute String.starts_with?(command, "  ")
      assert byte_size(command) <= 160
    end
  end

  test "a deterministic peer applies the ordered SMS plan and read-back contract" do
    assert {:ok, config} = ATC700Configuration.new(configuration())

    peer =
      Enum.reduce(ATC700Configuration.endpoint_sms_commands(config), %{}, fn command, state ->
        apply_setparam(command, state)
      end)

    assert Map.take(peer, ~w(2025 2001 2004 2005 2006 1004 113)) == %{
             "113" => "0",
             "1004" => "1",
             "2001" => "internet",
             "2004" => "tracker.example.test",
             "2005" => "5027",
             "2006" => "0",
             "2025" => "0"
           }
  end

  test "documented maximum field lengths retain the 160-byte SMS bound" do
    document =
      configuration()
      |> put_in(["sms", "password"], String.duplicate("s", 10))
      |> put_in(["cellular", "apn"], String.duplicate("a", 32))
      |> put_in(["cellular", "username"], String.duplicate("u", 32))
      |> put_in(["cellular", "password"], String.duplicate("p", 32))
      |> put_in(["cellular", "server"], String.duplicate("d", 55))
      |> put_in(["cellular", "port"], 65_535)

    assert {:ok, config} = ATC700Configuration.new(document)

    for command <-
          ATC700Configuration.endpoint_sms_commands(config) ++
            [ATC700Configuration.endpoint_verification_sms(config)] do
      assert byte_size(command) <= 160
    end
  end

  test "the closed contract rejects TAT140 authentication and unsupported settings" do
    valid = configuration()

    invalid = [
      %{},
      Map.put(valid, "schema", "wtr.atc700-configuration.v2"),
      Map.put(valid, "unknown", true),
      put_in(valid, ["provisioning_path"], "iphone_ble"),
      put_in(valid, ["sms"], %{"login" => "owner", "password" => "12345"}),
      put_in(valid, ["sms", "password"], "1234"),
      put_in(valid, ["sms", "password"], "password123"),
      put_in(valid, ["sms", "password"], "pass word"),
      put_in(valid, ["cellular", "apn"], "apn;2004:attacker.invalid"),
      put_in(valid, ["cellular", "username"], "user name"),
      put_in(valid, ["cellular", "password"], "secret\ncpureset"),
      put_in(valid, ["cellular", "server"], "https://tracker.example.test"),
      put_in(valid, ["cellular", "port"], 0),
      put_in(valid, ["cellular", "transport"], "udp"),
      put_in(valid, ["protocol", "data"], "codec8"),
      put_in(valid, ["protocol", "server_confirmation"], "tcp_ip")
    ]

    for document <- invalid do
      assert {:error, :invalid_configuration} = ATC700Configuration.new(document)
    end
  end

  defp configuration do
    %{
      "schema" => "wtr.atc700-configuration.v1",
      "provisioning_path" => "sms_and_teltonika_configurator_tct",
      "sms" => %{"password" => "12345"},
      "cellular" => %{
        "apn" => "internet",
        "username" => "subscriber",
        "password" => "private",
        "server" => "tracker.example.test",
        "port" => 5027,
        "transport" => "tcp"
      },
      "protocol" => %{
        "data" => "codec8_extended",
        "server_confirmation" => "avl"
      }
    }
  end

  defp apply_setparam(command, state) do
    [_password, "setparam", body] = String.split(command, " ", parts: 3)

    body
    |> String.split(";", trim: true)
    |> Enum.reduce(state, fn pair, accumulator ->
      [id, value] = String.split(pair, ":", parts: 2)
      Map.put(accumulator, id, value)
    end)
  end
end
