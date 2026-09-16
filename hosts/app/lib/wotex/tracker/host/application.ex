defmodule Wotex.Tracker.Host.Application do
  @moduledoc "Standalone host startup; the library packages remain inert."
  use Application
  alias Wotex.Tracker.Host.Config

  @impl true
  def start(_type, _args) do
    with {:ok, options} <- Config.load(System.get_env("WOTEX_TRACKER_CONFIG")),
         {:ok, browser} <-
           Config.load_browser(System.get_env("WOTEX_TRACKER_UI_CONFIG"), options),
         true <- is_nil(browser) or Code.ensure_loaded?(Wotex.Tracker.Host.Browser) do
      Wotex.Tracker.Host.Supervisor.start_link(service: options, browser: browser)
    else
      false -> {:error, :ui_not_in_artifact}
      error -> error
    end
  end
end
