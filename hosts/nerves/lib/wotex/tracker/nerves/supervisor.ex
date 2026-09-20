defmodule Wotex.Tracker.Nerves.Supervisor do
  @moduledoc """
  Separates the Nerves service from optional presentation processes.

  The service server is always supervised. A configured browser starts its
  loopback endpoint and session store; the Pi display launcher is an additional
  temporary child. A display failure does not restart the service or its
  durable store. Browser requests resolve the current service child instead
  of retaining an old process reference after a restart.
  """

  use Supervisor
  alias Wotex.Tracker.Nerves.NativeResourceSampler
  alias Wotex.Tracker.Service.Cellular.HostConfig
  alias Wotex.Tracker.Service.Cellular.Server, as: CellularServer
  alias Wotex.Tracker.Service.HTTP.{Config, Server}
  @kiosk_target Mix.target() == :rpi5

  def start_link(options), do: Supervisor.start_link(__MODULE__, options, name: __MODULE__)

  @impl true
  def init(options) do
    parent = self()
    {:ok, config} = Config.new(options[:service])

    provider = fn ->
      with {:ok, server} <- Server.child(parent, Server), do: Server.context(server, config)
    end

    server_provider = fn -> Server.child(parent, Server) end
    cellular = cellular_children(options[:cellular], provider)

    browser =
      if options[:browser] do
        [
          {Wotex.Tracker.Nerves.Browser, {options[:browser], provider, server_provider}}
        ]
      else
        []
      end

    kiosk = kiosk_children(options[:browser])

    Supervisor.init(
      [{Server, options[:service]}] ++
        cellular ++ [{NativeResourceSampler, []}] ++ browser ++ kiosk,
      strategy: :one_for_one
    )
  end

  defp cellular_children(nil, _provider), do: []

  defp cellular_children(%HostConfig{} = config, provider),
    do: [{CellularServer, HostConfig.server_options(config, provider)}]

  if @kiosk_target do
    defp kiosk_children(nil), do: []

    defp kiosk_children(config) do
      [
        Supervisor.child_spec(
          {Wotex.Tracker.Nerves.Kiosk, config},
          restart: :temporary
        )
      ]
    end
  else
    defp kiosk_children(_config), do: []
  end
end
