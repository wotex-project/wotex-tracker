defmodule Wotex.Tracker.Service.Cellular.HostConfigTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import Wotex.Tracker.Service.Fixtures

  alias Wotex.Tracker.Protocols.Teltonika.{TAT140, TCPSession}
  alias Wotex.Tracker.Service.Cellular.HostConfig
  alias Wotex.Tracker.Service.Credentials

  @imei "123456789012345"
  @identity_key :binary.copy(<<11>>, 32)

  test "a closed private document becomes redacted server configuration" do
    context = service()
    document = document(context.admin)

    assert {:ok, config} =
             HostConfig.new(document, context.credentials, :teltonika_tat140_codec8e)

    assert config.ip == {127, 0, 0, 1}
    assert config.port == 0
    refute inspect(config) =~ document["identity_key"]
    refute inspect(config) =~ context.admin
    refute inspect(config) =~ hd(document["devices"])["identity_digest"]

    assert [device] = config.devices
    assert device.id == "asset-one"
    assert device.profile == TAT140.configured_profile()

    provider = fn -> {:ok, context.service} end
    options = HostConfig.server_options(config, provider)
    assert options[:service] == provider
    assert options[:ip] == {127, 0, 0, 1}
    assert options[:port] == 0
  end

  test "absence is inert and malformed or unauthorized entries fail closed" do
    context = service()
    document = document(context.admin)
    assert {:ok, nil} = HostConfig.new(nil, context.credentials, :ruuvi_raw_v2)

    invalid = [
      Map.put(document, "schema", "wtr.cellular-host.v2"),
      Map.put(document, "transport", "tls"),
      Map.put(document, "identity_key", "invalid"),
      Map.put(document, "identity_key", nil),
      Map.put(document, "identity_key", Base.encode64(@identity_key, padding: false)),
      Map.put(document, "listen", %{"ip" => "localhost", "port" => 5027}),
      Map.put(document, "listen", %{"ip" => "127.0.0.1", "port" => -1}),
      Map.put(document, "listen", nil),
      Map.put(document, "devices", []),
      Map.put(document, "devices", nil),
      Map.put(document, "devices", [nil]),
      Map.put(document, "devices", List.duplicate(hd(document["devices"]), 33)),
      Map.put(document, "unknown", true),
      put_in(
        document,
        ["devices", Access.at(0), "token"],
        Credentials.generate_token()
      ),
      put_in(document, ["devices", Access.at(0), "profile"], "teltonika.unknown"),
      put_in(document, ["devices", Access.at(0), "identity_digest"], "bad")
    ]

    for candidate <- invalid do
      assert {:error, :invalid_configuration} =
               HostConfig.new(candidate, context.credentials, :teltonika_tat140_codec8e)
    end

    assert {:error, :invalid_configuration} =
             HostConfig.new(document, context.credentials, :ruuvi_raw_v2)

    assert {:error, :invalid_configuration} =
             HostConfig.new(%{}, context.credentials, :teltonika_tat140_codec8e)

    assert {:error, :invalid_configuration} =
             HostConfig.new(document, nil, :teltonika_tat140_codec8e)
  end

  test "duplicate routing identities and labels are rejected" do
    context = service()
    document = document(context.admin)
    [device] = document["devices"]

    for duplicate <- [
          %{device | "id" => "asset-two"},
          %{device | "identity_digest" => String.duplicate("a", 64)}
        ] do
      configured = Map.put(document, "devices", [device, duplicate])

      assert {:error, :invalid_configuration} =
               HostConfig.new(configured, context.credentials, :teltonika_tat140_codec8e)
    end
  end

  defp document(token) do
    {:ok, digest} = TCPSession.identity_digest(@imei, @identity_key)

    %{
      "schema" => "wtr.cellular-host.v1",
      "transport" => "clear_tcp",
      "listen" => %{"ip" => "127.0.0.1", "port" => 0},
      "identity_key" => Base.encode64(@identity_key),
      "devices" => [
        %{
          "identity_digest" => digest,
          "token" => token,
          "scope" => "workshop",
          "id" => "asset-one",
          "profile" => TAT140.configured_profile()
        }
      ]
    }
  end
end
