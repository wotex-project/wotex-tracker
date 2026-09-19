defmodule Wotex.Tracker.Mobile.MobScreen do
  @moduledoc """
  Native Mob screen containing only the bound local shared-UI WebView.

  External HTTPS navigation is handed to the OS browser. It never loads inside
  the bridge-bearing WebView.
  """

  use Mob.Screen
  alias Wotex.Tracker.Mobile.{ExternalURL, WebSession}

  @impl true
  def mount(%{session: %WebSession{} = session}, _stored, socket) do
    {:ok, Mob.Socket.assign(socket, :web_session, session)}
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
end
