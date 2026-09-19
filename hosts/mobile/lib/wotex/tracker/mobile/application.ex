defmodule Wotex.Tracker.Mobile.Application do
  @moduledoc """
  Owns the mobile host's explicitly configured local processes.

  The native Mob entry point and loopback presentation endpoint are added by
  later host slices. Loading a shared package never starts this application.
  """

  use Application
  alias Wotex.Tracker.Mobile.Host

  @impl true
  def start(_type, _args) do
    case Application.get_env(:wotex_tracker_mobile, :host) do
      nil ->
        Supervisor.start_link([], strategy: :one_for_one, name: Wotex.Tracker.Mobile.Supervisor)

      options ->
        Host.start_link(options)
    end
  end
end
