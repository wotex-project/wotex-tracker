defmodule Wotex.Tracker.Host.Supervisor do
  @moduledoc false

  use Supervisor
  alias Wotex.Tracker.Host.NativeResourceSampler
  alias Wotex.Tracker.Service.Cellular.HostConfig
  alias Wotex.Tracker.Service.Cellular.Server, as: CellularServer
  alias Wotex.Tracker.Service.HTTP.{Config, Server}

  def start_link(options), do: Supervisor.start_link(__MODULE__, options)

  @impl true
  def init(options) do
    parent = self()

    service =
      Keyword.put(
        options[:service],
        :cellular_ingress,
        if(options[:cellular], do: :configured, else: :unconfigured)
      )

    {:ok, config} = Config.new(service)

    provider = fn ->
      with {:ok, server} <- Server.child(parent, Server), do: Server.context(server, config)
    end

    server_provider = fn -> Server.child(parent, Server) end

    cellular = cellular_children(options[:cellular], provider)

    browser =
      if options[:browser],
        do: [{Wotex.Tracker.Host.Browser, {options[:browser], provider, server_provider}}],
        else: []

    native =
      case Keyword.get_lazy(options, :native_resource, fn ->
             NativeResourceSampler.default_source(:os.type())
           end) do
        nil -> []
        source -> [{NativeResourceSampler, source: source}]
      end

    Supervisor.init(
      [{Server, service}] ++ cellular ++ browser ++ native,
      strategy: :rest_for_one
    )
  end

  defp cellular_children(nil, _provider), do: []

  defp cellular_children(%HostConfig{} = config, provider),
    do: [{CellularServer, HostConfig.server_options(config, provider)}]
end
