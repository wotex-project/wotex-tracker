defmodule Wotex.Tracker.Mobile.Notifications do
  @moduledoc """
  Closed native notification permission, token and tap boundary.

  The only admitted notification data is the service's exact opaque reference
  projection. Resolving it navigates the existing local WebView to the shared
  alert screen, where the current session reauthorizes and fetches the alert.
  """

  alias Wotex.Tracker.Mobile.NotificationRegistration

  @schema "wtr.notification-reference.v1"
  @registrar NotificationRegistration

  @doc "Requests the native notification permission without widening the bridge."
  @spec request_permission(Mob.Socket.t(), module()) :: Mob.Socket.t()
  def request_permission(socket, permissions \\ Mob.Permissions),
    do: native(socket, permissions, :request, [:notifications])

  @doc "Begins native push-token registration after permission is granted."
  @spec register_push(Mob.Socket.t(), module()) :: Mob.Socket.t()
  def register_push(socket, notify \\ MobNotify),
    do: native(socket, notify, :register_push, [])

  @doc "Forwards one bounded iOS token to the non-secret registration owner."
  @spec register_endpoint(term(), GenServer.server()) :: :ok
  def register_endpoint(token, registrar \\ @registrar) do
    NotificationRegistration.register(registrar, :ios, token)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc "Removes this installation's endpoint after notification permission denial."
  @spec unregister_endpoint(GenServer.server()) :: :ok
  def unregister_endpoint(registrar \\ @registrar) do
    NotificationRegistration.unregister(registrar)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc "Retries a volatile token after session or network recovery."
  @spec retry_registration(GenServer.server()) :: :ok
  def retry_registration(registrar \\ @registrar) do
    NotificationRegistration.retry(registrar)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc "Routes an exact opaque event reference to its authorized local alert page."
  @spec route(Mob.Socket.t(), term(), module()) :: Mob.Socket.t()
  def route(socket, payload, webview \\ Mob.WebView) do
    with {:ok, reference} <- reference(payload),
         path = "/protection/alerts/" <> URI.encode(reference, &URI.char_unreserved?/1),
         {:ok, encoded} <- Jason.encode(path),
         %Mob.Socket{} = updated <-
           webview.eval_js(socket, "window.location.assign(" <> encoded <> ")") do
      updated
    else
      _ -> socket
    end
  rescue
    _ -> socket
  catch
    _, _ -> socket
  end

  defp reference(%{data: data}) when is_map(data), do: reference_data(data)
  defp reference(%{"data" => data}) when is_map(data), do: reference_data(data)
  defp reference(_), do: {:error, :invalid_notification}

  defp reference_data(%{schema: @schema, event_ref: reference} = data)
       when map_size(data) == 2,
       do: valid_reference(reference)

  defp reference_data(%{"schema" => @schema, "event_ref" => reference} = data)
       when map_size(data) == 2,
       do: valid_reference(reference)

  defp reference_data(_), do: {:error, :invalid_notification}

  defp valid_reference(reference)
       when is_binary(reference) and byte_size(reference) in 1..256 do
    if String.valid?(reference),
      do: {:ok, reference},
      else: {:error, :invalid_notification}
  end

  defp valid_reference(_), do: {:error, :invalid_notification}

  defp native(socket, module, function, arguments) when is_atom(module) do
    case apply(module, function, [socket | arguments]) do
      %Mob.Socket{} = updated -> updated
      _ -> socket
    end
  rescue
    _ -> socket
  catch
    _, _ -> socket
  end
end
