defmodule Wotex.Tracker.Protocols.Teltonika.EYESensorConfiguration do
  @moduledoc """
  Closed mobile BLE command contract for a Teltonika EYE Sensor.

  This module describes only the manufacturer-published BTSMP1 GATT surface:
  the configuration service, six-digit password, sensor activation mask and
  write-to-flash command. It does not describe a TAT140 phone interface. The
  TAT140 consumes the EYE Sensor's advertisements after its separate SMS/USB
  configuration.

  Source: https://wiki.teltonika-gps.com/view/BTSMP1
  """

  import Bitwise

  @command_schema "wtr.mobile-ble-central-command.v1"
  @event_schema "wtr.mobile-ble-central-event.v1"
  @service "e61c0000-7df2-4d4e-8e6d-c611745b92e9"
  @password "e61c0008-7df2-4d4e-8e6d-c611745b92e9"
  @command "e61c0007-7df2-4d4e-8e6d-c611745b92e9"
  @sensor_mask "e61c0021-7df2-4d4e-8e6d-c611745b92e9"
  @operation ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
  @uuid16 ~r/\A[0-9a-f]{4}\z/
  @uuid32 ~r/\A[0-9a-f]{8}\z/
  @uuid128 ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @reasons ~w(unavailable unsupported unauthorized powered_off resetting busy not_found not_connected invalid_data)
  @properties ~w(authenticated_signed_writes broadcast extended_properties indicate indicate_encryption_required notify notify_encryption_required read write write_without_response)
  @sensor_bits [temperature: 0, humidity: 1, magnetic: 2, movement: 3]

  @type sensor :: :temperature | :humidity | :magnetic | :movement

  @doc "Returns the exact manufacturer configuration service UUID."
  @spec service_uuid() :: String.t()
  def service_uuid, do: @service

  @doc "Returns the characteristics required by the bounded configuration flow."
  @spec required_characteristics() :: [String.t()]
  def required_characteristics, do: Enum.sort([@command, @password, @sensor_mask])

  @doc "Builds a bounded scan command for only the EYE configuration service."
  @spec scan_command(String.t(), pos_integer()) :: {:ok, map()} | {:error, :invalid_command}
  def scan_command(request, timeout_ms \\ 10_000)

  def scan_command(request, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms in 1_000..30_000 do
    command(request, "scan", %{"service_uuids" => [@service], "timeout_ms" => timeout_ms})
  end

  def scan_command(_, _), do: {:error, :invalid_command}

  @doc "Builds a connection command for one admitted native peripheral ID."
  @spec connect_command(String.t(), String.t()) :: {:ok, map()} | {:error, :invalid_command}
  def connect_command(request, peripheral),
    do: peripheral_command(request, "connect", peripheral)

  @doc "Builds a disconnect command for one admitted native peripheral ID."
  @spec disconnect_command(String.t(), String.t()) :: {:ok, map()} | {:error, :invalid_command}
  def disconnect_command(request, peripheral),
    do: peripheral_command(request, "disconnect", peripheral)

  @doc "Builds service discovery restricted to the EYE configuration service."
  @spec discover_command(String.t(), String.t()) :: {:ok, map()} | {:error, :invalid_command}
  def discover_command(request, peripheral) do
    with {:ok, base} <- peripheral_command(request, "discover", peripheral) do
      {:ok, Map.put(base, "service_uuids", [@service])}
    end
  end

  @doc "Builds the exact six-ASCII-digit authentication write."
  @spec authenticate_command(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, :invalid_command}
  def authenticate_command(request, peripheral, password)
      when is_binary(password) and byte_size(password) == 6 do
    if Regex.match?(~r/\A[0-9]{6}\z/, password) do
      write_command(request, peripheral, @password, password)
    else
      {:error, :invalid_command}
    end
  end

  def authenticate_command(_, _, _), do: {:error, :invalid_command}

  @doc "Builds the exact one-byte sensor activation write."
  @spec sensor_mask_command(String.t(), String.t(), [sensor()]) ::
          {:ok, map()} | {:error, :invalid_command}
  def sensor_mask_command(request, peripheral, sensors) when is_list(sensors) do
    with {:ok, mask} <- sensor_mask(sensors) do
      write_command(request, peripheral, @sensor_mask, <<mask>>)
    end
  end

  def sensor_mask_command(_, _, _), do: {:error, :invalid_command}

  @doc "Builds the documented `0x0010` write-to-flash command."
  @spec save_command(String.t(), String.t()) :: {:ok, map()} | {:error, :invalid_command}
  def save_command(request, peripheral),
    do: write_command(request, peripheral, @command, <<0x00, 0x10>>)

  @doc "Builds a read used to verify the exact active sensor mask."
  @spec read_sensor_mask_command(String.t(), String.t()) ::
          {:ok, map()} | {:error, :invalid_command}
  def read_sensor_mask_command(request, peripheral) do
    with {:ok, base} <- peripheral_command(request, "read", peripheral) do
      {:ok,
       Map.merge(base, %{
         "service_uuid" => @service,
         "characteristic_uuid" => @sensor_mask
       })}
    end
  end

  @doc "Encodes a unique, closed sensor selection into the published four-bit mask."
  @spec sensor_mask([sensor()]) :: {:ok, 0..15} | {:error, :invalid_sensor_mask}
  def sensor_mask(sensors) when is_list(sensors) do
    if sensors == Enum.uniq(sensors) and Enum.all?(sensors, &Keyword.has_key?(@sensor_bits, &1)) do
      {:ok,
       Enum.reduce(sensors, 0, fn sensor, mask ->
         mask ||| 1 <<< Keyword.fetch!(@sensor_bits, sensor)
       end)}
    else
      {:error, :invalid_sensor_mask}
    end
  end

  def sensor_mask(_), do: {:error, :invalid_sensor_mask}

  @doc "Decodes the one-byte mask returned by the EYE characteristic."
  @spec decode_sensor_mask(String.t()) ::
          {:ok, %{mask: 0..15, sensors: [sensor()]}} | {:error, :invalid_value}
  def decode_sensor_mask(encoded) when is_binary(encoded) do
    with {:ok, <<mask>>} <- Base.url_decode64(encoded, padding: false),
         true <- mask in 0..15 do
      sensors =
        for {sensor, bit} <- @sensor_bits, (mask &&& 1 <<< bit) != 0, do: sensor

      {:ok, %{mask: mask, sensors: sensors}}
    else
      _ -> {:error, :invalid_value}
    end
  end

  def decode_sensor_mask(_), do: {:error, :invalid_value}

  @doc "Validates one target event after the generic native bridge has decoded it."
  @spec decode_event(term()) :: {:ok, map()} | {:error, :invalid_event}
  def decode_event(
        %{
          "schema" => @event_schema,
          "request_id" => request,
          "event" => event,
          "data" => data
        } = envelope
      )
      when map_size(envelope) == 4 and is_binary(event) and is_map(data) do
    if operation?(request) and valid_event?(event, data) do
      {:ok, %{"request_id" => request, "event" => event, "data" => data}}
    else
      {:error, :invalid_event}
    end
  end

  def decode_event(_), do: {:error, :invalid_event}

  defp command(request, operation, fields) do
    if operation?(request) do
      {:ok,
       Map.merge(fields, %{
         "schema" => @command_schema,
         "request_id" => request,
         "operation" => operation
       })}
    else
      {:error, :invalid_command}
    end
  end

  defp peripheral_command(request, operation, peripheral) do
    if peripheral?(peripheral) do
      command(request, operation, %{"peripheral_id" => peripheral})
    else
      {:error, :invalid_command}
    end
  end

  defp write_command(request, peripheral, characteristic, value) do
    with {:ok, base} <- peripheral_command(request, "write", peripheral) do
      {:ok,
       Map.merge(base, %{
         "service_uuid" => @service,
         "characteristic_uuid" => characteristic,
         "encoding" => "base64url",
         "value" => Base.url_encode64(value, padding: false)
       })}
    end
  end

  defp valid_event?("rejected", %{"reason" => reason} = data),
    do: map_size(data) == 1 and reason in @reasons

  defp valid_event?(event, %{"reason" => reason} = data)
       when event in ~w(connect_failed operation_failed),
       do: map_size(data) == 1 and reason in @reasons

  defp valid_event?(event, %{"peripheral_id" => peripheral} = data)
       when event in ~w(connected disconnected),
       do: map_size(data) == 1 and peripheral?(peripheral)

  defp valid_event?("scan_result", data) do
    match?(
      %{
        "peripheral_id" => _peripheral,
        "name" => _name,
        "rssi" => rssi,
        "service_uuids" => services
      }
      when is_integer(rssi) and rssi in -127..20 and is_list(services),
      data
    ) and map_size(data) == 4 and peripheral?(data["peripheral_id"]) and
      valid_name?(data["name"]) and data["service_uuids"] == [@service]
  end

  defp valid_event?(event, data)
       when event in ~w(scan_complete scan_stopped discovery_complete),
       do: data == %{}

  defp valid_event?(
         "services",
         %{"peripheral_id" => peripheral, "service_uuids" => services} = data
       ),
       do: map_size(data) == 2 and peripheral?(peripheral) and services == [@service]

  defp valid_event?("characteristics", data) do
    match?(
      %{
        "peripheral_id" => _peripheral,
        "service_uuid" => @service,
        "characteristics" => characteristics
      }
      when is_list(characteristics),
      data
    ) and map_size(data) == 3 and peripheral?(data["peripheral_id"]) and
      valid_characteristics?(data["characteristics"])
  end

  defp valid_event?(event, data) when event in ~w(value written) do
    expected = if event == "value", do: 4, else: 3

    map_size(data) == expected and peripheral?(data["peripheral_id"]) and
      data["service_uuid"] == @service and
      data["characteristic_uuid"] in required_characteristics() and
      (event == "written" or valid_value?(data["value"]))
  end

  defp valid_event?(_, _), do: false

  defp valid_characteristics?(values) do
    uuids =
      if is_list(values) do
        Enum.map(values, fn
          %{"uuid" => uuid} -> uuid
          _ -> nil
        end)
      else
        []
      end

    is_list(values) and length(values) in 1..64 and uuids == Enum.uniq(uuids) and
      Enum.all?(values, fn
        %{"uuid" => uuid, "properties" => properties} = value
        when map_size(value) == 2 and is_list(properties) ->
          uuid?(uuid) and
            properties == properties |> Enum.uniq() |> Enum.sort() and
            Enum.all?(properties, &(&1 in @properties))

        _ ->
          false
      end)
  end

  defp valid_value?(encoded) when is_binary(encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, value} ->
        byte_size(value) in 1..512 and Base.url_encode64(value, padding: false) == encoded

      :error ->
        false
    end
  end

  defp valid_value?(_), do: false
  defp valid_name?(nil), do: true

  defp valid_name?(value),
    do: is_binary(value) and byte_size(value) in 1..128 and String.valid?(value)

  defp operation?(value), do: is_binary(value) and Regex.match?(@operation, value)
  defp peripheral?(value), do: is_binary(value) and Regex.match?(@uuid128, value)

  defp uuid?(value) when is_binary(value),
    do:
      Regex.match?(@uuid16, value) or Regex.match?(@uuid32, value) or
        Regex.match?(@uuid128, value)

  defp uuid?(_), do: false
end
