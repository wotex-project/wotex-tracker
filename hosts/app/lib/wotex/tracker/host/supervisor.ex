defmodule Wotex.Tracker.Host.Supervisor do
  @moduledoc false

  use Supervisor
  alias Wotex.Tracker.Host.NativeResourceSampler
  alias Wotex.Tracker.Service.APNsHostConfig
  alias Wotex.Tracker.Service.Cellular.HostConfig
  alias Wotex.Tracker.Service.Cellular.Server, as: CellularServer
  alias Wotex.Tracker.Service.HTTP.{Config, Server}
  alias Wotex.Tracker.Service.{PassiveIngress, PassiveScanner}

  def start_link(options), do: Supervisor.start_link(__MODULE__, options)

  @impl true
  def init(options) do
    parent = self()

    service =
      options[:service]
      |> Keyword.put(
        :cellular_ingress,
        if(options[:cellular], do: :configured, else: :unconfigured)
      )
      |> notification_dispatcher(options[:apns])

    {:ok, config} = Config.new(service)

    provider = fn ->
      with {:ok, server} <- Server.child(parent, Server), do: Server.context(server, config)
    end

    server_provider = fn -> Server.child(parent, Server) end

    cellular = cellular_children(options[:cellular], provider)
    passive = passive_children(options[:passive], provider)

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
      [{Server, service}] ++ cellular ++ passive ++ browser ++ native,
      strategy: :rest_for_one
    )
  end

  defp cellular_children(nil, _provider), do: []

  defp cellular_children(%HostConfig{} = config, provider),
    do: [{CellularServer, HostConfig.server_options(config, provider)}]

  defp passive_children(nil, _provider), do: []

  defp passive_children(%{ingress: ingress, scanner: scanner}, provider)
       when is_list(ingress) and is_list(scanner) do
    ingress_name = Wotex.Tracker.Host.Development.PassiveIngress

    [
      {PassiveIngress, Keyword.merge(ingress, service: provider, name: ingress_name)},
      {PassiveScanner, Keyword.merge(scanner, ingress: ingress_name)}
    ]
  end

  defp notification_dispatcher(options, nil), do: options

  defp notification_dispatcher(options, %APNsHostConfig{} = config),
    do: Keyword.put(options, :notification_dispatcher, APNsHostConfig.dispatcher_options(config))
end
