defmodule Wotex.Tracker.Service.Cellular.Server do
  @moduledoc """
  Explicit bounded TCP service for configured Teltonika Codec 8 Extended peers.

  Starting the module owns one listener and one serialized `Cellular.Ingress`
  process. Loading the package starts no sockets. The listener uses one acceptor,
  a finite connection budget and per-phase read deadlines. Clear TCP matches the
  tracker protocol; an IMEI remains a configured routing identifier rather than
  cryptographic device authentication.
  """

  use Supervisor

  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.Cellular.{Connection, Ingress}

  @maximum_sessions 32
  @maximum_timeout 300_000

  @doc "Starts one explicitly configured cellular ingress and TCP listener."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options) when is_list(options) do
    with {:ok, config, server_options} <- options(options),
         do: Supervisor.start_link(__MODULE__, config, server_options)
  end

  def start_link(_), do: {:error, :invalid_configuration}

  @doc "Returns the actual bound address without private device configuration."
  @spec listener_info(Supervisor.supervisor()) ::
          {:ok, {:inet.ip_address(), :inet.port_number()}} | {:error, :unavailable}
  def listener_info(server) do
    with {:ok, listener} <- child(server, :listener),
         {:ok, info} <- ThousandIsland.listener_info(listener) do
      {:ok, info}
    else
      _ -> {:error, :unavailable}
    end
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc false
  @spec ingress(Supervisor.supervisor()) :: {:ok, pid()} | {:error, :unavailable}
  def ingress(server), do: child(server, :ingress)

  @impl true
  def init(config) do
    children = [
      Supervisor.child_spec({Ingress, config.ingress}, id: :ingress),
      Supervisor.child_spec(
        {ThousandIsland, listener(config, self())},
        id: :listener
      )
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp child(server, id) do
    case List.keyfind(Supervisor.which_children(server), id, 0) do
      {^id, pid, _, _} when is_pid(pid) -> {:ok, pid}
      _ -> {:error, :unavailable}
    end
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp options(options) do
    allowed = [
      :service,
      :identity_key,
      :devices,
      :ip,
      :port,
      :login_timeout_ms,
      :frame_timeout_ms,
      :send_timeout_ms,
      :shutdown_timeout_ms,
      :clock,
      :maximum_sessions,
      :maximum_retries,
      :name
    ]

    required = [:service, :identity_key, :devices, :ip, :port]

    if Keyword.keyword?(options) and
         length(options) == length(Enum.uniq(Keyword.keys(options))) and
         Enum.all?(Keyword.keys(options), &(&1 in allowed)) and
         Enum.all?(required, &Keyword.has_key?(options, &1)) do
      config = %{
        ip: Keyword.fetch!(options, :ip),
        port: Keyword.fetch!(options, :port),
        login_timeout_ms: Keyword.get(options, :login_timeout_ms, 5_000),
        frame_timeout_ms: Keyword.get(options, :frame_timeout_ms, 60_000),
        send_timeout_ms: Keyword.get(options, :send_timeout_ms, 5_000),
        shutdown_timeout_ms: Keyword.get(options, :shutdown_timeout_ms, 5_000),
        maximum_sessions: Keyword.get(options, :maximum_sessions, @maximum_sessions),
        ingress:
          Keyword.take(options, [
            :service,
            :identity_key,
            :devices,
            :clock,
            :maximum_sessions,
            :maximum_retries
          ])
      }

      if config?(config) and Ingress.validate_options(config.ingress) == :ok,
        do: {:ok, config, Keyword.take(options, [:name])},
        else: {:error, :invalid_configuration}
    else
      {:error, :invalid_configuration}
    end
  end

  defp config?(config) do
    match?(%Service{}, Keyword.get(config.ingress, :service)) and network?(config) and
      timeouts?(config) and session_limit?(config.maximum_sessions)
  end

  defp network?(config),
    do: ip?(config.ip) and is_integer(config.port) and config.port in 0..65_535

  defp timeouts?(config),
    do:
      timeout?(config.login_timeout_ms) and timeout?(config.frame_timeout_ms) and
        timeout?(config.send_timeout_ms) and timeout?(config.shutdown_timeout_ms)

  defp session_limit?(value),
    do: is_integer(value) and value in 1..@maximum_sessions

  defp timeout?(value), do: is_integer(value) and value in 1..@maximum_timeout

  defp ip?(ip) when is_tuple(ip) and tuple_size(ip) in [4, 8],
    do: ip |> Tuple.to_list() |> Enum.all?(&valid_ip_part?(&1, tuple_size(ip)))

  defp ip?(_), do: false

  defp valid_ip_part?(part, 4), do: is_integer(part) and part in 0..255
  defp valid_ip_part?(part, 8), do: is_integer(part) and part in 0..65_535

  defp listener(config, server) do
    [
      handler_module: Connection,
      handler_options: %{
        server: server,
        login_timeout_ms: config.login_timeout_ms,
        frame_timeout_ms: config.frame_timeout_ms
      },
      port: config.port,
      num_acceptors: 1,
      num_connections: config.maximum_sessions,
      max_connections_retry_count: 0,
      read_timeout: max(config.login_timeout_ms, config.frame_timeout_ms),
      shutdown_timeout: config.shutdown_timeout_ms,
      silent_terminate_on_error: true,
      transport_options: [
        ip: config.ip,
        nodelay: true,
        reuseaddr: true,
        send_timeout: config.send_timeout_ms,
        send_timeout_close: true,
        recbuf: 32_768,
        buffer: 32_768
      ]
    ]
  end
end
