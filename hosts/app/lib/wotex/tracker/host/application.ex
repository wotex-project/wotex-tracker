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
         {:ok, browser} <-
           Config.load_browser(System.get_env("WOTEX_TRACKER_UI_CONFIG"), options),
         true <- is_nil(browser) or Code.ensure_loaded?(Wotex.Tracker.Host.Browser) do
      Wotex.Tracker.Host.Supervisor.start_link(
        service: options,
        browser: browser,
        cellular: cellular
      )
    else
      false -> {:error, :ui_not_in_artifact}
      error -> error
    end
  end
end
