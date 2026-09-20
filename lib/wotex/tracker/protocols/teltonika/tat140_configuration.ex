defmodule Wotex.Tracker.Protocols.Teltonika.TAT140Configuration do
  @moduledoc """
  Closed documentation-backed configuration plan for the TAT140 baseline.

  The documented SMS surface is used only for APN and operator-controlled TCP
  endpoint parameters. Codec 8 Extended and EYE Sensor slot configuration are
  represented as Teltonika Configurator USB settings because the current
  TAT140 documentation does not publish numeric SMS parameter IDs for those
  fields. The plan therefore does not imply a phone-to-tracker BLE protocol.
  """

  alias Wotex.Tracker.Protocols.Teltonika.TAT140

  @maximum_sms_bytes 160
  @provisioning_path "teltonika_configurator_usb"
  @eye_avl_ids %{
    "temperature" => 25,
    "battery" => 29,
    "humidity" => 86,
    "movement_counter" => 463
  }

  @derive {Inspect,
           only: [
             :provisioning_path,
             :server,
             :port,
             :sensor_slot,
             :ble_update_frequency_seconds
           ]}
  @enforce_keys [
    :provisioning_path,
    :sms_login,
    :sms_password,
    :apn,
    :apn_username,
    :apn_password,
    :server,
    :port,
    :sensor_mac,
    :sensor_slot,
    :ble_update_frequency_seconds,
    :lost_sensor_alarm
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          provisioning_path: String.t(),
          sms_login: String.t(),
          sms_password: String.t(),
          apn: String.t(),
          apn_username: String.t(),
          apn_password: String.t(),
          server: String.t(),
          port: :inet.port_number(),
          sensor_mac: String.t(),
          sensor_slot: 1,
          ble_update_frequency_seconds: pos_integer(),
          lost_sensor_alarm: boolean()
        }

  @doc "Admits one exact endpoint and EYE Sensor slot-one configuration."
  @spec new(term()) :: {:ok, t()} | {:error, :invalid_configuration}
  def new(
        %{
          "schema" => "wtr.tat140-configuration.v1",
          "provisioning_path" => @provisioning_path,
          "sms" => %{"login" => sms_login, "password" => sms_password} = sms,
          "cellular" =>
            %{
              "apn" => apn,
              "username" => apn_username,
              "password" => apn_password,
              "server" => server,
              "port" => port,
              "transport" => "tcp"
            } = cellular,
          "protocol" => %{"data" => "codec8_extended"} = protocol,
          "ble" =>
            %{
              "feature" => "sensors",
              "sensor" => "eye_sensor",
              "slot" => 1,
              "mac" => sensor_mac,
              "update_frequency_seconds" => update_frequency,
              "lost_sensor_alarm" => lost_sensor_alarm
            } = ble
        } = document
      )
      when map_size(document) == 6 and map_size(sms) == 2 and map_size(cellular) == 6 and
             map_size(protocol) == 1 and map_size(ble) == 6 do
    config = %__MODULE__{
      provisioning_path: @provisioning_path,
      sms_login: sms_login,
      sms_password: sms_password,
      apn: apn,
      apn_username: apn_username,
      apn_password: apn_password,
      server: server,
      port: port,
      sensor_mac: sensor_mac,
      sensor_slot: 1,
      ble_update_frequency_seconds: update_frequency,
      lost_sensor_alarm: lost_sensor_alarm
    }

    if valid?(config), do: {:ok, config}, else: {:error, :invalid_configuration}
  end

  def new(_), do: {:error, :invalid_configuration}

  @doc "Renders the ordered, independently bounded SMS endpoint command batch."
  @spec endpoint_sms_commands(t()) :: [String.t()]
  def endpoint_sms_commands(%__MODULE__{} = config) do
    prefix = sms_prefix(config)

    [
      prefix <>
        "setparam 2001:#{config.apn};2002:#{config.apn_username};2003:#{config.apn_password}",
      prefix <> "setparam 2004:#{config.server};2005:#{config.port};2006:0"
    ]
  end

  @doc "Renders a bounded read-back command for the non-secret endpoint fields."
  @spec endpoint_verification_sms(t()) :: String.t()
  def endpoint_verification_sms(%__MODULE__{} = config),
    do: sms_prefix(config) <> "getparam 2001;2004;2005;2006"

  @doc "Returns the exact USB Configurator selections not represented by SMS IDs."
  @spec configurator_manifest(t()) :: map()
  def configurator_manifest(%__MODULE__{} = config) do
    %{
      "schema" => "wtr.tat140-configurator-manifest.v1",
      "provisioning_path" => config.provisioning_path,
      "profile" => TAT140.configured_profile(),
      "system" => %{"data_protocol" => "Codec 8 Extended"},
      "bluetooth" => %{
        "ble_feature" => "Sensors",
        "update_frequency_seconds" => config.ble_update_frequency_seconds,
        "sensor_table" => [
          %{
            "slot" => config.sensor_slot,
            "preset" => "EYE Sensor (Sensors)",
            "mac" => config.sensor_mac,
            "lost_sensor_alarm" => config.lost_sensor_alarm,
            "expected_avl_ids" => @eye_avl_ids
          }
        ]
      }
    }
  end

  @doc "Returns the expected non-secret endpoint parameter values for read-back."
  @spec endpoint_expectations(t()) :: map()
  def endpoint_expectations(%__MODULE__{} = config),
    do: %{"2001" => config.apn, "2004" => config.server, "2005" => config.port, "2006" => 0}

  defp valid?(config) do
    sms_credentials?(config.sms_login, config.sms_password) and
      parameter?(config.apn, 1..32, ~r/\A[A-Za-z0-9.-]+\z/) and
      parameter?(config.apn_username, 0..32, ~r/\A[A-Za-z0-9._@+-]*\z/) and
      parameter?(config.apn_password, 0..32, ~r/\A[A-Za-z0-9._@+-]*\z/) and
      parameter?(config.server, 1..55, ~r/\A[A-Za-z0-9.-]+\z/) and
      is_integer(config.port) and config.port in 1..65_535 and
      Regex.match?(~r/\A[0-9A-F]{2}(?::[0-9A-F]{2}){5}\z/, config.sensor_mac) and
      is_integer(config.ble_update_frequency_seconds) and
      config.ble_update_frequency_seconds in 30..65_535 and
      is_boolean(config.lost_sensor_alarm) and bounded_commands?(config)
  end

  defp sms_credentials?("", ""), do: true

  defp sms_credentials?(login, password),
    do:
      parameter?(login, 1..5, ~r/\A[A-Za-z0-9]+\z/) and
        parameter?(password, 1..5, ~r/\A[A-Za-z0-9]+\z/)

  defp parameter?(value, range, pattern),
    do: is_binary(value) and byte_size(value) in range and Regex.match?(pattern, value)

  defp sms_prefix(%__MODULE__{sms_login: login, sms_password: password}),
    do: login <> " " <> password <> " "

  defp bounded_commands?(config) do
    Enum.all?(
      endpoint_sms_commands(config) ++ [endpoint_verification_sms(config)],
      &(byte_size(&1) <= @maximum_sms_bytes)
    )
  end
end
