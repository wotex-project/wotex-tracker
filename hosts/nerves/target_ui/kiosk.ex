defmodule Wotex.Tracker.Nerves.Kiosk do
  @moduledoc """
  Launches the Pi kiosk only after a DRM display card appears.

  The launcher gives display startup a finite retry budget and monitors the
  display process. It is a temporary child beside the service and browser,
  so a missing or stopped display does not restart ingestion or the store.
  This module is compiled only for the UI-enabled Pi target.
  """

  use GenServer
  require Logger

  @retry_ms 500
  @max_attempts 20

  def start_link(config), do: GenServer.start_link(__MODULE__, config)

  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)
    send(self(), :launch)
    {:ok, %{config: config, attempts: 0, display: nil}}
  end

  @impl true
  def handle_info(:launch, %{attempts: @max_attempts} = state) do
    Logger.error("Pi display unavailable after #{@max_attempts} attempts")
    {:noreply, state}
  end

  def handle_info(:launch, state) do
    next = %{state | attempts: state.attempts + 1}

    case display_ready?() do
      true ->
        case Wotex.Tracker.Nerves.Kiosk.Process.start_link(state.config) do
          {:ok, display} ->
            Process.monitor(display)
            Process.unlink(display)
            {:noreply, %{next | display: display}}

          {:error, reason} ->
            Logger.warning("Pi display launch failed: #{inspect(reason)}")
            retry(next)
        end

      false ->
        retry(next)
    end
  end

  def handle_info({:DOWN, _ref, :process, display, reason}, %{display: display} = state) do
    Logger.warning("Pi display stopped: #{inspect(reason)}")
    retry(%{state | display: nil})
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp retry(state) do
    Process.send_after(self(), :launch, @retry_ms)
    {:noreply, state}
  end

  defp display_ready? do
    case File.ls("/dev/dri") do
      {:ok, devices} -> Enum.any?(devices, &Regex.match?(~r/^card[0-9]+$/, &1))
      _ -> false
    end
  end
end
