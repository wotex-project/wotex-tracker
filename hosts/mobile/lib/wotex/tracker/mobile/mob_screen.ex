defmodule Wotex.Tracker.Mobile.MobScreen do
  @moduledoc """
  Native Mob screen containing only the bound local shared-UI WebView.

  External HTTPS navigation is handed to the OS browser. It never loads inside
  the bridge-bearing WebView.
  """

  use Mob.Screen
  alias Wotex.Mobile.BLECentral
  alias Wotex.Tracker.Mobile.{ExternalURL, Lifecycle, Notifications, Sharing, WebSession}

  @impl true
  def mount(%{session: %WebSession{} = session}, _stored, socket) do
    {:ok, ready(socket, session)}
  end

  def mount(%{setup: configure}, _stored, socket) when is_function(configure, 1) do
    {:ok,
     Mob.Socket.assign(socket,
       mode: :setup,
       remote_origin: "",
       setup_error: nil,
       configure: configure
     )}
  end

  def mount(_, _, _), do: {:error, :invalid_session}

  @impl true
  def render(%{mode: :web, web_session: session}) do
    target = WebSession.target(session)
    Mob.UI.webview(url: target.url, allow: target.allow, show_url: false)
  end

  def render(%{mode: :setup} = assigns) do
    %{
      type: :scroll,
      props: %{background: :background},
      children: [
        %{
          type: :column,
          props: %{background: :background, padding: :space_lg},
          children:
            [
              native_text("Connect WoTEx Tracker", :xl, :on_surface),
              native_text(
                "Enter the canonical HTTPS origin of infrastructure you control.",
                :md,
                :muted
              ),
              %{type: :spacer, props: %{size: 24}, children: []},
              %{
                type: :text_field,
                props: %{
                  value: assigns.remote_origin,
                  placeholder: "https://tracker.example",
                  keyboard: :url,
                  return_key: :done,
                  on_change: {self(), :remote_origin}
                },
                children: []
              },
              %{type: :spacer, props: %{size: 16}, children: []},
              %{
                type: :button,
                props: %{
                  text: "Connect",
                  background: :primary,
                  text_color: :on_primary,
                  text_size: :lg,
                  padding: :space_md,
                  on_tap: {self(), :connect}
                },
                children: []
              }
            ] ++ setup_error(assigns.setup_error)
        }
      ]
    }
  end

  def handle_info({:change, :remote_origin, value}, socket)
      when is_binary(value) and byte_size(value) <= 2_048 do
    {:noreply, Mob.Socket.assign(socket, remote_origin: value, setup_error: nil)}
  end

  def handle_info({:change, :remote_origin, _}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :setup_error, :invalid)}

  def handle_info({:tap, :connect}, %{assigns: %{mode: :setup}} = socket) do
    case configure(socket.assigns.configure, socket.assigns.remote_origin) do
      {:ok, %WebSession{} = session} -> {:noreply, ready(socket, session)}
      _ -> {:noreply, Mob.Socket.assign(socket, :setup_error, :invalid)}
    end
  end

  @impl true
  def handle_info({:webview, :blocked, url}, socket) do
    _ = open_external_url(url)
    {:noreply, socket}
  end

  def handle_info(
        {:webview, :message, %{"schema" => "wtr.mobile-ble-central-command.v1"} = command},
        socket
      ),
      do: {:noreply, BLECentral.execute(socket, command)}

  def handle_info({:webview, :message, payload}, socket),
    do: {:noreply, Sharing.share(socket, payload)}

  def handle_info({:ble_central, _, _, _} = event, socket),
    do: {:noreply, BLECentral.deliver(socket, event)}

  def handle_info({:mob_device, _, _} = event, socket), do: lifecycle(event, socket)
  def handle_info({:mob_device, _} = event, socket), do: lifecycle(event, socket)

  def handle_info({:permission, :notifications, :granted}, socket),
    do: {:noreply, Notifications.register_push(socket)}

  def handle_info({:permission, :notifications, :denied}, socket) do
    _ = Notifications.unregister_endpoint()
    {:noreply, socket}
  end

  def handle_info({:push_token, :ios, token}, socket) do
    _ = Notifications.register_endpoint(token)
    {:noreply, socket}
  end

  def handle_info({:notification, payload}, socket),
    do: {:noreply, Notifications.route(socket, payload)}

  def handle_info(_, socket), do: {:noreply, socket}

  @doc false
  @spec open_external_url(term(), module()) :: :ok
  def open_external_url(url, device \\ Mob.Device) do
    case ExternalURL.admit(url) do
      {:ok, external} -> _ = device.open_url(external)
      {:error, :invalid_url} -> :ok
    end

    :ok
  end

  defp lifecycle(event, %{assigns: %{lifecycle: lifecycle}} = socket) do
    {lifecycle, effect} = Lifecycle.transition(lifecycle, event)
    socket = Mob.Socket.assign(socket, :lifecycle, lifecycle)

    socket =
      if effect == :reload do
        _ = Notifications.retry_registration()
        Lifecycle.reload(socket)
      else
        socket
      end

    {:noreply, socket}
  end

  defp ready(socket, session) do
    _ = Lifecycle.subscribe()

    socket =
      Mob.Socket.assign(socket,
        mode: :web,
        web_session: session,
        lifecycle: Lifecycle.new()
      )

    if is_map(session.notification), do: Notifications.request_permission(socket), else: socket
  end

  defp configure(function, origin) do
    function.(origin)
  rescue
    _ -> {:error, :native_runtime_unavailable}
  catch
    _, _ -> {:error, :native_runtime_unavailable}
  end

  defp native_text(text, size, color) do
    %{
      type: :text,
      props: %{text: text, text_size: size, text_color: color, padding: :space_sm},
      children: []
    }
  end

  defp setup_error(nil), do: []

  defp setup_error(:invalid) do
    [
      %{type: :spacer, props: %{size: 12}, children: []},
      native_text("Use an exact HTTPS service origin and try again.", :sm, :error)
    ]
  end
end
