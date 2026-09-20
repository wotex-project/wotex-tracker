defmodule Wotex.Tracker.Mobile.Development.ScreenSimulator do
  @moduledoc """
  Process-owned execution of the real root-screen callbacks for local development.

  It does not emulate a browser or invent a second bridge contract. Commands
  enter through the same `MobScreen.handle_info/2` clauses used by the packaged
  application, and native events arrive from `NativeSimulator`.
  """

  use GenServer

  alias Wotex.Tracker.Mobile.{MobScreen, NativeAdapters, WebSession}

  @keys ~w(name session)a

  @doc "Starts one development root screen around an admitted Web session."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) when is_list(options) do
    name = Keyword.get(options, :name, __MODULE__)
    session = Keyword.get(options, :session)

    if valid_options?(options) and is_atom(name) and match?(%WebSession{}, session) do
      GenServer.start_link(__MODULE__, session, name: name)
    else
      {:error, :invalid_configuration}
    end
  end

  def start_link(_), do: {:error, :invalid_configuration}

  @doc "Sends one packaged-page bridge message through the real root screen."
  @spec message(term(), GenServer.server()) :: :ok | {:error, :unavailable}
  def message(payload, server \\ __MODULE__), do: call(server, {:webview, :message, payload})

  @doc "Sends one blocked navigation through the real root screen."
  @spec blocked(term(), GenServer.server()) :: :ok | {:error, :unavailable}
  def blocked(url, server \\ __MODULE__), do: call(server, {:webview, :blocked, url})

  @doc "Returns a redacted projection of the simulated root screen."
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  catch
    :exit, _ -> %{mode: :development, state: :unavailable}
  end

  @doc "Renders the current native root projection for local inspection."
  @spec render(GenServer.server()) :: term()
  def render(server \\ __MODULE__), do: GenServer.call(server, :render)

  @impl true
  def init(%WebSession{} = session) do
    with {:ok, native} <- NativeAdapters.development(),
         socket <- Mob.Socket.new(MobScreen),
         {:ok, socket} <- MobScreen.mount(%{session: session, native: native}, %{}, socket) do
      {:ok, socket}
    else
      _ -> {:stop, :invalid_configuration}
    end
  end

  @impl true
  def handle_call(:status, _from, socket) do
    lifecycle = socket.assigns.lifecycle

    status = %{
      mode: socket.assigns.mode,
      app: lifecycle.app,
      network: lifecycle.network,
      notification_permission: socket.assigns[:simulated_notification_permission],
      push_registration: socket.assigns[:simulated_push_registration] == true,
      shared: socket.assigns[:simulated_share] == true,
      webview_effect: socket.assigns[:simulated_webview_effect] == true
    }

    {:reply, status, socket}
  end

  def handle_call(:render, _from, socket),
    do: {:reply, MobScreen.render(socket.assigns), socket}

  def handle_call(event, _from, socket) do
    {:noreply, updated} = MobScreen.handle_info(event, socket)
    {:reply, :ok, updated}
  end

  @impl true
  def handle_info(event, socket) do
    {:noreply, updated} = MobScreen.handle_info(event, socket)
    {:noreply, updated}
  end

  @impl true
  def format_status(status) do
    status
    |> Map.replace(:state, :redacted)
    |> Map.replace(:message, :redacted)
    |> Map.replace(:log, [])
  end

  defp valid_options?(options) do
    Keyword.keyword?(options) and length(options) == map_size(Map.new(options)) and
      Keyword.keys(options) -- @keys == []
  end

  defp call(server, message) do
    GenServer.call(server, message)
  catch
    :exit, _ -> {:error, :unavailable}
  end
end
