defmodule Wotex.Tracker.Nerves.Application do
  @moduledoc "Headless Pi host; the shared library and service remain inert until started here."
  use Application
  alias Wotex.Tracker.Nerves.Config
  alias Wotex.Tracker.Service.HTTP.Server

  @impl true
  def start(_type, _args) do
    with {:ok, options} <-
           Config.load(
             Application.get_env(:wotex_tracker_nerves, :config_path),
             Application.get_env(:wotex_tracker_nerves, :data_root)
           ) do
      Supervisor.start_link([{Server, options}],
        strategy: :one_for_one,
        name: Wotex.Tracker.Nerves.Supervisor
      )
    end
  end
end
