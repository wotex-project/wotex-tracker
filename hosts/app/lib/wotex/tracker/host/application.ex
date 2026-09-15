defmodule Wotex.Tracker.Host.Application do
  @moduledoc "Standalone host startup; the library packages remain inert."
  use Application
  alias Wotex.Tracker.Host.Config
  alias Wotex.Tracker.Service.HTTP.Server

  @impl true
  def start(_type, _args) do
    with {:ok, options} <- Config.load(System.get_env("WOTEX_TRACKER_CONFIG")) do
      Supervisor.start_link([{Server, options}], strategy: :one_for_one)
    end
  end
end
