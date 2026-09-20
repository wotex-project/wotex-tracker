defmodule Wotex.Tracker.Host.Application do
  @moduledoc """
  Starts the standalone Tracker service host.

  Startup loads private service configuration and optional browser
  configuration before supervising either component. Requesting a browser
  from a headless artifact fails instead of starting a partial UI. The root,
  service, and shared UI library packages do not start this host themselves.
  """

  use Application
  alias Wotex.Tracker.Host.Config

  @impl true
  def start(_type, _args) do
    with {:ok, options} <- Config.load(System.get_env("WOTEX_TRACKER_CONFIG")),
         {:ok, cellular} <-
           Config.load_cellular(System.get_env("WOTEX_TRACKER_CELLULAR_CONFIG"), options),
         {:ok, apns} <- Config.load_apns(System.get_env("WOTEX_TRACKER_APNS_CONFIG"), options),
         {:ok, passive} <-
           Config.load_passive(
             System.get_env("WOTEX_TRACKER_PASSIVE_CONFIG"),
             options,
             Application.get_env(:wotex_tracker_host, :passive_adapter)
           ),
         {:ok, selected_passive} <-
           passive_config(
             passive,
             System.get_env("WOTEX_TRACKER_PASSIVE_SIMULATOR_CONFIG"),
             options
           ),
         {:ok, browser} <-
           Config.load_browser(System.get_env("WOTEX_TRACKER_UI_CONFIG"), options),
         true <- is_nil(browser) or Code.ensure_loaded?(Wotex.Tracker.Host.Browser) do
      Wotex.Tracker.Host.Supervisor.start_link(
        service: options,
        browser: browser,
        cellular: cellular,
        apns: apns,
        passive: selected_passive
      )
    else
      false -> {:error, :ui_not_in_artifact}
      error -> error
    end
  end

  defp passive_config(passive, simulator_path, options) do
    with {:ok, simulator} <- Config.load_passive_simulator(simulator_path, options),
         true <- is_nil(passive) or is_nil(simulator) do
      {:ok, passive || simulator}
    else
      _ -> {:error, :invalid_configuration}
    end
  end
end
