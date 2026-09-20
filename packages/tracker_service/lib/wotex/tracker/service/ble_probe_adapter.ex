defmodule Wotex.Tracker.Service.BLEProbeAdapter do
  @moduledoc """
  Optional read-only active-probe adapter for an explicit `Wotex.BLE` session.

  The host selects and owns the session, peer, connection mode and any pairing
  material. This adapter neither opens nor closes a session. It converts only a
  closed `ble_gatt` read request into the upstream byte-valued GATT operation,
  performs no retry and returns no upstream diagnostic details.

  `wotex_ble` is an optional service dependency. Hosts that configure this
  adapter must include that package; its absence is an unavailable adapter, not
  a service-startup failure.
  """

  @behaviour Wotex.Tracker.Service.ActiveProbeAdapter

  @impl true
  def read(session, request, timeout_ms) do
    ble = Wotex.BLE

    with true <- available?(),
         true <- session?(session),
         {:ok, target} <- target(request),
         result <-
           ble.read(
             session,
             target,
             value_type: :bytes,
             byte_order: :little,
             timeout: timeout_ms
           ) do
      normalize(result)
    else
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp available? do
    Code.ensure_loaded?(Wotex.BLE) and Code.ensure_loaded?(Wotex.BLE.Session) and
      function_exported?(Wotex.BLE, :read, 3)
  end

  defp session?(session), do: is_struct(session, Wotex.BLE.Session)

  defp target(
         %{
           "schema" => "wtr.active-probe-adapter-request.v1",
           "transport" => "ble_gatt",
           "operation" => "read",
           "target" => %{
             "service_uuid" => service,
             "characteristic_uuid" => characteristic,
             "handle" => handle,
             "object_path" => object_path,
             "generation" => generation
           }
         } = request
       )
       when map_size(request) == 4 do
    {:ok,
     %{
       service: service,
       characteristic: characteristic,
       handle: handle,
       object_path: object_path,
       generation: generation
     }}
  end

  defp target(_), do: {:error, :unavailable}

  defp normalize({:ok, value}) when is_binary(value), do: {:ok, value}

  defp normalize({:error, %{__struct__: Wotex.BLE.Error, code: code}})
       when code in [:not_authorized, :not_permitted, :pairing_rejected],
       do: {:error, :rejected}

  defp normalize(_), do: {:error, :unavailable}
end
