defmodule Wotex.Mobile.BLECentral do
  @moduledoc """
  Closed, versioned command and event boundary for the iOS BLE central plugin.

  This surface owns only CoreBluetooth transport primitives. Target protocol,
  identity and WoT mapping stay outside the mobile shell.
  """

  @native :wotex_ble_central_nif
  @command_schema "wtr.mobile-ble-central-command.v1"
  @event_schema "wtr.mobile-ble-central-event.v1"
  @operation ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
  @uuid16 ~r/\A[0-9a-f]{4}\z/
  @uuid32 ~r/\A[0-9a-f]{8}\z/
  @uuid128 ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @maximum_value_bytes 512
  @maximum_event_bytes 16_384
  @reasons ~w(unavailable unsupported unauthorized powered_off resetting busy not_found not_connected invalid_data)a
  @properties ~w(authenticated_signed_writes broadcast extended_properties indicate indicate_encryption_required notify notify_encryption_required read write write_without_response)a

  @doc "Executes one exact native BLE command and returns the socket unchanged."
  @spec execute(term(), term(), module()) :: term()
  def execute(socket, command, native \\ @native)

  def execute(%{__struct__: Mob.Socket} = socket, command, native) when is_atom(native) do
    case call(command) do
      {:ok, request, function, arguments} -> invoke(socket, request, native, function, arguments)
      :error -> socket
    end
  end

  def execute(socket, _, _), do: socket

  @doc "Delivers one validated native event to the packaged WebView."
  @spec deliver(term(), term(), module()) :: term()
  def deliver(socket, event, webview \\ Mob.WebView)

  def deliver(%{__struct__: Mob.Socket} = socket, event, webview) when is_atom(webview) do
    with {:ok, envelope} <- envelope(event),
         {:ok, encoded} <- Jason.encode(envelope),
         true <- byte_size(encoded) <= @maximum_event_bytes,
         {:ok, json} <- Jason.encode(encoded),
         script =
           "window.dispatchEvent(new CustomEvent(\"wotex:ble-central\",{detail:JSON.parse(" <>
             json <> ")}))",
         %{__struct__: Mob.Socket} = updated <- webview.eval_js(socket, script) do
      updated
    else
      _ -> socket
    end
  rescue
    _ -> socket
  catch
    _, _ -> socket
  end

  def deliver(socket, _, _), do: socket

  defp call(
         %{
           "schema" => @command_schema,
           "request_id" => request,
           "operation" => "scan",
           "service_uuids" => services,
           "timeout_ms" => timeout
         } = command
       )
       when map_size(command) == 5 and timeout in 1_000..30_000 do
    with true <- operation?(request),
         {:ok, services} <- uuid_list(services, 8) do
      {:ok, request, :scan, [request, services, timeout]}
    else
      _ -> :error
    end
  end

  defp call(
         %{
           "schema" => @command_schema,
           "request_id" => request,
           "operation" => "stop_scan"
         } = command
       )
       when map_size(command) == 3 do
    if operation?(request), do: {:ok, request, :stop_scan, [request]}, else: :error
  end

  defp call(
         %{
           "schema" => @command_schema,
           "request_id" => request,
           "operation" => operation,
           "peripheral_id" => peripheral
         } = command
       )
       when map_size(command) == 4 and operation in ~w(connect disconnect) do
    if operation?(request) and peripheral?(peripheral) do
      {:ok, request, String.to_existing_atom(operation), [request, peripheral]}
    else
      :error
    end
  end

  defp call(
         %{
           "schema" => @command_schema,
           "request_id" => request,
           "operation" => "discover",
           "peripheral_id" => peripheral,
           "service_uuids" => services
         } = command
       )
       when map_size(command) == 5 do
    with true <- operation?(request) and peripheral?(peripheral),
         {:ok, services} <- uuid_list(services, 8) do
      {:ok, request, :discover, [request, peripheral, services]}
    else
      _ -> :error
    end
  end

  defp call(
         %{
           "schema" => @command_schema,
           "request_id" => request,
           "operation" => "read",
           "peripheral_id" => peripheral,
           "service_uuid" => service,
           "characteristic_uuid" => characteristic
         } = command
       )
       when map_size(command) == 6 do
    if operation?(request) and peripheral?(peripheral) and uuid?(service) and
         uuid?(characteristic) do
      {:ok, request, :read, [request, peripheral, service, characteristic]}
    else
      :error
    end
  end

  defp call(
         %{
           "schema" => @command_schema,
           "request_id" => request,
           "operation" => "write",
           "peripheral_id" => peripheral,
           "service_uuid" => service,
           "characteristic_uuid" => characteristic,
           "encoding" => "base64url",
           "value" => encoded
         } = command
       )
       when map_size(command) == 8 and is_binary(encoded) do
    with true <- operation?(request) and peripheral?(peripheral),
         true <- uuid?(service) and uuid?(characteristic),
         {:ok, value} <- Base.url_decode64(encoded, padding: false),
         true <- byte_size(value) in 1..@maximum_value_bytes,
         true <- Base.url_encode64(value, padding: false) == encoded do
      {:ok, request, :write, [request, peripheral, service, characteristic, value]}
    else
      _ -> :error
    end
  end

  defp call(_), do: :error

  defp invoke(socket, request, native, function, arguments) do
    case apply(native, function, arguments) do
      :ok -> socket
      {:error, reason} -> reject(socket, request, reason)
      _ -> reject(socket, request, :unavailable)
    end
  rescue
    _ -> reject(socket, request, :unavailable)
  catch
    _, _ -> reject(socket, request, :unavailable)
  end

  defp reject(socket, request, reason) do
    reason = if reason in @reasons, do: reason, else: :unavailable
    send(self(), {:ble_central, request, :rejected, reason})
    socket
  end

  defp envelope({:ble_central, request, :rejected, reason})
       when reason in @reasons do
    event(request, "rejected", %{"reason" => Atom.to_string(reason)})
  end

  defp envelope({:ble_central, request, event, peripheral})
       when event in [:connected, :disconnected] do
    if peripheral?(peripheral), do: event(request, Atom.to_string(event), %{"peripheral_id" => peripheral}), else: :error
  end

  defp envelope({:ble_central, request, event, reason})
       when event in [:connect_failed, :operation_failed] and reason in @reasons do
    event(request, Atom.to_string(event), %{"reason" => Atom.to_string(reason)})
  end

  defp envelope({:ble_central, request, event, nil})
       when event in [:scan_complete, :scan_stopped, :discovery_complete],
       do: event(request, Atom.to_string(event), %{})

  defp envelope({:ble_central, request, :scan_result, {peripheral, name, rssi, services}}) do
    with true <- peripheral?(peripheral),
         true <- valid_name?(name),
         true <- is_integer(rssi) and rssi in -127..20,
         {:ok, services} <- uuid_list(services, 16) do
      event(request, "scan_result", %{
        "peripheral_id" => peripheral,
        "name" => name,
        "rssi" => rssi,
        "service_uuids" => services
      })
    else
      _ -> :error
    end
  end

  defp envelope({:ble_central, request, :services, {peripheral, services}}) do
    with true <- peripheral?(peripheral),
         {:ok, services} <- uuid_list(services, 32) do
      event(request, "services", %{"peripheral_id" => peripheral, "service_uuids" => services})
    else
      _ -> :error
    end
  end

  defp envelope(
         {:ble_central, request, :characteristics, {peripheral, service, characteristics}}
       ) do
    with true <- peripheral?(peripheral) and uuid?(service),
         {:ok, characteristics} <- characteristics(characteristics) do
      event(request, "characteristics", %{
        "peripheral_id" => peripheral,
        "service_uuid" => service,
        "characteristics" => characteristics
      })
    else
      _ -> :error
    end
  end

  defp envelope(
         {:ble_central, request, event, {peripheral, service, characteristic, value}}
       )
       when event in [:value, :written] and is_binary(value) and
              byte_size(value) <= @maximum_value_bytes do
    if peripheral?(peripheral) and uuid?(service) and uuid?(characteristic) do
      data = %{
        "peripheral_id" => peripheral,
        "service_uuid" => service,
        "characteristic_uuid" => characteristic
      }

      data = if event == :value, do: Map.put(data, "value", Base.url_encode64(value, padding: false)), else: data
      event(request, Atom.to_string(event), data)
    else
      :error
    end
  end

  defp envelope(_), do: :error

  defp event(request, name, data) do
    if operation?(request) do
      {:ok,
       %{
         "schema" => @event_schema,
         "request_id" => request,
         "event" => name,
         "data" => data
       }}
    else
      :error
    end
  end

  defp characteristics(values) when is_list(values) and length(values) <= 64 do
    Enum.reduce_while(values, {:ok, []}, fn
      {uuid, properties}, {:ok, acc} when is_list(properties) ->
        if uuid?(uuid) and properties == properties |> Enum.uniq() |> Enum.sort() and
             Enum.all?(properties, &(&1 in @properties)) do
          {:cont,
           {:ok,
            [
              %{"uuid" => uuid, "properties" => Enum.map(properties, &Atom.to_string/1)}
              | acc
            ]}}
        else
          {:halt, :error}
        end

      _, _ ->
        {:halt, :error}
    end)
    |> case do
      {:ok, result} -> {:ok, Enum.reverse(result)}
      :error -> :error
    end
  end

  defp characteristics(_), do: :error

  defp uuid_list(values, maximum)
       when is_list(values) and length(values) >= 1 and length(values) <= maximum do
    if values == values |> Enum.uniq() |> Enum.sort() and Enum.all?(values, &uuid?/1),
      do: {:ok, values},
      else: :error
  end

  defp uuid_list(_, _), do: :error

  defp operation?(value), do: is_binary(value) and Regex.match?(@operation, value)
  defp peripheral?(value), do: is_binary(value) and Regex.match?(@uuid128, value)

  defp uuid?(value) when is_binary(value),
    do: Regex.match?(@uuid16, value) or Regex.match?(@uuid32, value) or Regex.match?(@uuid128, value)

  defp uuid?(_), do: false

  defp valid_name?(nil), do: true

  defp valid_name?(name),
    do: is_binary(name) and byte_size(name) in 1..128 and String.valid?(name)
end
