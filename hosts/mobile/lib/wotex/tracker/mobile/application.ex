defmodule Wotex.Tracker.Mobile.Application do
  @moduledoc """
  Owns the mobile host's explicitly configured local processes.

  The application supervisor remains available during native first-run setup;
  the loopback host is then installed as one replaceable dynamic child. Loading
  a shared package never starts this application.
  """

  use Application
  alias Wotex.Tracker.Mobile.Host

  @application_supervisor Wotex.Tracker.Mobile.ApplicationSupervisor
  @host_supervisor Wotex.Tracker.Mobile.HostSupervisor
  @host Wotex.Tracker.Mobile.Supervisor

  @impl true
  def start(_type, _args) do
    children = [{DynamicSupervisor, strategy: :one_for_one, name: @host_supervisor}]

    case Supervisor.start_link(children, strategy: :one_for_one, name: @application_supervisor) do
      {:ok, supervisor} -> configured(supervisor)
      {:error, _} = error -> error
    end
  end

  @doc false
  @spec start_host(keyword()) :: DynamicSupervisor.on_start_child()
  def start_host(options) when is_list(options),
    do: DynamicSupervisor.start_child(@host_supervisor, {Host, options})

  @doc false
  @spec replace_host(keyword()) :: DynamicSupervisor.on_start_child()
  def replace_host(options) when is_list(options) do
    with :ok <- stop_host(), do: start_host(options)
  end

  defp start_configured_host do
    case Application.get_env(:wotex_tracker_mobile, :host) do
      nil -> :ok
      options -> normalize_start(start_host(options))
    end
  end

  defp normalize_start({:ok, _}), do: :ok
  defp normalize_start({:error, _} = error), do: error

  defp configured(supervisor) do
    case start_configured_host() do
      :ok ->
        {:ok, supervisor}

      {:error, _} = error ->
        Supervisor.stop(supervisor)
        error
    end
  end

  defp stop_host do
    case Process.whereis(@host) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(@host_supervisor, pid)
    end
  end
end
