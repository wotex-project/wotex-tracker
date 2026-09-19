defmodule Wotex.Tracker.Mobile.Lifecycle do
  @moduledoc """
  Bounded foreground and network recovery for the local presentation WebView.

  The native shell owns only a small transition state. Returning from a real
  background state or regaining an online path reloads the current local page
  once, which makes the shared UI reauthorize and resnapshot through its normal
  client. No request, mutation or page-provided value crosses this boundary.
  """

  @reload "window.location.reload()"
  @derive {Inspect, only: [:app, :network]}
  defstruct app: :active, network: :unknown

  @type t :: %__MODULE__{
          app: :active | :background,
          network: :unknown | :online | :offline
        }

  @doc "Returns the initial foreground state without querying native APIs."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Subscribes the current screen to only app and connectivity events."
  @spec subscribe(module()) :: :ok | {:error, :native_runtime_unavailable}
  def subscribe(device \\ Mob.Device) when is_atom(device) do
    case device.subscribe([:app, :network]) do
      :ok -> :ok
      _ -> {:error, :native_runtime_unavailable}
    end
  rescue
    _ -> {:error, :native_runtime_unavailable}
  catch
    _, _ -> {:error, :native_runtime_unavailable}
  end

  @doc "Reduces one native event and reports whether the local page must reload."
  @spec transition(t(), term()) :: {t(), :reload | :none}
  def transition(%__MODULE__{} = state, {:mob_device, :did_enter_background}),
    do: {%{state | app: :background}, :none}

  def transition(%__MODULE__{app: :background} = state, {:mob_device, :did_become_active}),
    do: {%{state | app: :active}, :reload}

  def transition(%__MODULE__{} = state, {:mob_device, :did_become_active}),
    do: {%{state | app: :active}, :none}

  def transition(
        %__MODULE__{app: :active, network: network} = state,
        {:mob_device, :connectivity_changed, %{online: true}}
      )
      when network != :online,
      do: {%{state | network: :online}, :reload}

  def transition(%__MODULE__{} = state, {:mob_device, :connectivity_changed, %{online: true}}),
    do: {%{state | network: :online}, :none}

  def transition(%__MODULE__{} = state, {:mob_device, :connectivity_changed, %{online: false}}),
    do: {%{state | network: :offline}, :none}

  def transition(%__MODULE__{} = state, _), do: {state, :none}

  @doc "Performs the one fixed local reload effect and contains native failures."
  @spec reload(Mob.Socket.t(), module()) :: Mob.Socket.t()
  def reload(socket, webview \\ Mob.WebView) when is_atom(webview) do
    case webview.eval_js(socket, @reload) do
      %Mob.Socket{} = updated -> updated
      _ -> socket
    end
  rescue
    _ -> socket
  catch
    _, _ -> socket
  end
end
