defmodule Wotex.Tracker.Service.PassiveHostConfigTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import Wotex.Tracker.Service.Fixtures

  alias Wotex.Tracker.Service.Credentials
  alias Wotex.Tracker.Service.Development.PassiveSimulator
  alias Wotex.Tracker.Service.PassiveHostConfig
  alias Wotex.Tracker.Service.PassiveIngress
  alias Wotex.Tracker.Service.PassiveScanner

  test "a closed private document composes the common ingress and scanner" do
    context = service()
    document = document(context.admin)
    adapter = {PassiveSimulator, []}

    assert {:ok, config} = PassiveHostConfig.new(document, context.credentials, adapter)
    assert config.adapter_id == "bluez-hci0"
    assert config.scope == context.scope
    assert config.adapter == adapter
    refute inspect(config) =~ context.admin

    assert [ingress, scanner] = PassiveHostConfig.child_specs(config, context.service, :ingress)
    assert {PassiveIngress, ingress_options} = ingress
    assert ingress_options[:service] == context.service
    assert ingress_options[:token] == context.admin
    assert ingress_options[:scope] == context.scope
    assert ingress_options[:adapter] == "bluez-hci0"
    assert ingress_options[:name] == :ingress
    assert {PassiveScanner, scanner_options} = scanner
    assert scanner_options[:adapter] == adapter
    assert scanner_options[:ingress] == :ingress
    assert scanner_options[:interval_ms] == 250
    assert scanner_options[:timeout_ms] == 1_000
  end

  test "configuration is optional and rejects data-selected code or excess authority" do
    context = service()
    adapter = {PassiveSimulator, []}
    valid = document(context.admin)

    assert {:ok, nil} = PassiveHostConfig.new(nil, context.credentials, adapter)

    for invalid <- [
          %{},
          Map.put(valid, "schema", "wtr.passive-ble-host.v2"),
          Map.put(valid, "module", "Elixir.System"),
          Map.put(valid, "adapter", ""),
          Map.put(valid, "scope", "other"),
          Map.put(valid, "token", Credentials.generate_token()),
          Map.put(valid, "interval_ms", -1),
          Map.put(valid, "timeout_ms", 0),
          Map.put(valid, "timeout_ms", 30_001)
        ] do
      assert {:error, :invalid_configuration} =
               PassiveHostConfig.new(invalid, context.credentials, adapter)
    end

    assert {:error, :invalid_configuration} =
             PassiveHostConfig.new(valid, context.credentials, {String, nil})

    assert {:error, :invalid_configuration} =
             PassiveHostConfig.new(valid, context.credentials, :data_selected_adapter)
  end

  defp document(token) do
    %{
      "schema" => "wtr.passive-ble-host.v1",
      "adapter" => "bluez-hci0",
      "token" => token,
      "scope" => "workshop",
      "interval_ms" => 250,
      "timeout_ms" => 1_000
    }
  end
end
