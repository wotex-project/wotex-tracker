defmodule Wotex.Tracker.Host.Supervisor do
  @moduledoc false

  use Supervisor
  alias Wotex.Tracker.Service.HTTP.{Config, Server}

  def start_link(options), do: Supervisor.start_link(__MODULE__, options)

  @impl true
  def init(options) do
    parent = self()
    {:ok, config} = Config.new(options[:service])

    provider = fn ->
      with {:ok, server} <- Server.child(parent, Server), do: Server.context(server, config)
    end

    server_provider = fn -> Server.child(parent, Server) end

    browser =
      if options[:browser],
        do: [{Wotex.Tracker.Host.Browser, {options[:browser], provider, server_provider}}],
        else: []

    Supervisor.init([{Server, options[:service]}] ++ browser, strategy: :rest_for_one)
  end
end
