defmodule Wotex.Tracker.Mobile.MobScreen do
  @moduledoc """
  Native Mob screen containing only the bound local shared-UI WebView.

  External HTTPS navigation is handed to the OS browser. It never loads inside
  the bridge-bearing WebView.
  """

  use Mob.Screen
  alias Wotex.Tracker.Mobile.{ExternalURL, Lifecycle, Notifications, Sharing, WebSession}

  @impl true
  def mount(%{session: %WebSession{} = session}, _stored, socket) do
    _ = Lifecycle.subscribe()

    socket =
      Mob.Socket.assign(socket,
        web_session: session,
        lifecycle: Lifecycle.new()
      )

    socket =
      if is_map(session.notification), do: Notifications.request_permission(socket), else: socket

    {:ok, socket}
  end

  def mount(_, _, _), do: {:error, :invalid_session}

  @impl true
  def render(%{web_session: session}) do
    target = WebSession.target(session)
    Mob.UI.webview(url: target.url, allow: target.allow, show_url: false)
  end

  @impl true
  def handle_info({:webview, :blocked, url}, socket) do
    _ = open_external_url(url)
    {:noreply, socket}
  end

  def handle_info({:webview, :message, payload}, socket),
    do: {:noreply, Sharing.share(socket, payload)}

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
end
