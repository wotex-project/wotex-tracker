defmodule Wotex.Tracker.Service.HTTP.Server do
  @moduledoc """
  Explicit per-instance HTTP supervision. No listener is started by application loading.

  Supply credentials, a private directory, bind IP/port, public origin and exposure
  (`:loopback`, `:tls` or explicitly trusted `:proxy`). Proxy mode requires an HTTPS
  public origin and an operator-protected path from proxy to listener. The server
  never trusts forwarded headers for Forms or authentication. `:listener` derives
  the origin from a loopback listener, including an OS-assigned port.
  """

  use Supervisor
  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.HTTP.{Capacity, Config, Router}
  alias Wotex.Tracker.Service.{OperationalHistory, ResourceSampler, RuleScheduler, Store}

  @doc "Starts a fully explicit isolated service instance; invalid configuration starts nothing."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options) do
    with {:ok, config} <- Config.new(options), do: Supervisor.start_link(__MODULE__, config)
  end

  @doc "Returns the actual bound IP/port, without credentials or filesystem paths."
  @spec listener_info(pid()) :: {:ok, term()} | {:error, :storage_unavailable}
  def listener_info(server) do
    with {:ok, listener} <- child(server, :listener),
         {:ok, info} <- ThousandIsland.listener_info(listener) do
      {:ok, info}
    else
      _ -> {:error, :storage_unavailable}
    end
  catch
    :exit, _ -> {:error, :storage_unavailable}
  end

  @doc "Returns a bounded volatile operational snapshot from this host instance."
  def operational_history(server, options \\ []) do
    with {:ok, collector} <- child(server, :operational_history),
         do: OperationalHistory.snapshot(collector, options)
  end

  @doc "Returns bounded host-only rule deadline metadata."
  def rule_schedule(server) do
    with {:ok, scheduler} <- child(server, :rule_scheduler),
         do: RuleScheduler.snapshot(scheduler)
  end

  @doc false
  def context(server, config) do
    with {:ok, store} <- child(server, :store),
         {:ok, origin} <- origin(server, config) do
      Service.new(%{
        store: Store.handle(store),
        credentials: config.credentials,
        base_url: origin
      })
    end
  end

  @doc false
  def child(server, id) do
    case List.keyfind(Supervisor.which_children(server), id, 0) do
      {^id, pid, _, _} when is_pid(pid) -> {:ok, pid}
      _ -> {:error, :storage_unavailable}
    end
  catch
    :exit, _ -> {:error, :storage_unavailable}
  end

  @impl true
  def init(config) do
    store_options =
      Keyword.merge(config.store_options,
        directory: config.directory,
        credentials: config.credentials,
        clock: config.clock
      )

    children = [
      Supervisor.child_spec(
        {OperationalHistory, Keyword.put(config.operational_history, :clock, config.clock)},
        id: :operational_history
      ),
      Supervisor.child_spec({Capacity, config}, id: :capacity),
      Supervisor.child_spec({Store, store_options}, id: :store),
      Supervisor.child_spec(
        {RuleScheduler,
         Keyword.merge(config.rule_scheduler,
           store: {:supervisor, self()},
           clock: config.clock
         )},
        id: :rule_scheduler
      ),
      Supervisor.child_spec({Bandit, listener(config, self())}, id: :listener),
      Supervisor.child_spec({ResourceSampler, []}, id: :resource_sampler)
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp origin(server, %{public_origin: :listener}) do
    with {:ok, {ip, port}} <- listener_info(server) do
      host = ip |> :inet.ntoa() |> to_string()
      host = if tuple_size(ip) == 8, do: "[" <> host <> "]", else: host
      {:ok, "http://" <> host <> ":" <> Integer.to_string(port)}
    end
  end

  defp origin(_, config), do: {:ok, config.public_origin}

  defp listener(config, server) do
    options = [
      plug: {Router, {server, config}},
      ip: config.ip,
      port: config.port,
      scheme: if(config.exposure == :tls, do: :https, else: :http),
      startup_log: false,
      http_options: [
        compress: false,
        log_exceptions_with_status_codes: [],
        log_protocol_errors: false
      ],
      http_1_options: [
        max_request_line_length: 8192,
        max_header_length: 8192,
        max_header_count: 32,
        max_requests: 1
      ],
      http_2_options: [enabled: false],
      websocket_options: [enabled: false],
      thousand_island_options: [
        num_acceptors: 4,
        num_connections: 16,
        max_connections_retry_count: 0,
        read_timeout: 5000,
        shutdown_timeout: 5000,
        transport_options: [send_timeout: 5000, send_timeout_close: true]
      ]
    ]

    if config.tls, do: Keyword.merge(options, Map.to_list(config.tls)), else: options
  end
end
