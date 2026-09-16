defmodule Wotex.Tracker.Service.HTTP.LoopbackClient do
  @moduledoc """
  Explicit HTTP binding client for local Tracker Property reads and observation.

  Configuration admits one numeric loopback origin and one scope. Only finite
  `readproperty` GETs and bounded `observeproperty` SSE streams are supported.
  Credentials arrive separately at execution; configuration, requests, errors
  and subscription readers contain none. Finite calls own their socket; each
  subscription owns one monitored reader and closes independently. There is no
  pool, DNS, proxy, redirect, retry or automatic reconnect.

  The caller owns its Runtime credential provider. This is a local peer adapter,
  with caller-selected credentials and subscription lifetimes.
  """

  @behaviour Wotex.Binding.HTTP.Client
  alias Mint.HTTP1, as: HTTP
  alias Wotex.Binding.HTTP.{Headers, Request, Response}
  alias Wotex.Runtime.Context
  alias Wotex.Tracker.Service.{Codec, Credentials}
  alias Wotex.Tracker.Service.HTTP.SSEClient

  @enforce_keys [:origin, :scope, :ip, :host, :port]
  defstruct @enforce_keys

  @doc "Admits an HTTP origin at 127.0.0.1 or ::1 and an explicit Tracker scope."
  def new(origin, scope) when is_binary(origin) do
    with {:ok, uri} <- URI.new(origin),
         true <- uri.scheme == "http" and uri.host in ["127.0.0.1", "::1"],
         true <- uri.path in [nil, ""] and is_nil(uri.query) and is_nil(uri.fragment),
         true <- is_nil(uri.userinfo) and uri.port in 1..65_535 and Codec.id?(scope),
         {:ok, ip} <- :inet.parse_address(String.to_charlist(uri.host)) do
      {:ok, %__MODULE__{origin: origin, scope: scope, ip: ip, host: uri.host, port: uri.port}}
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  def new(_, _), do: {:error, :invalid_configuration}

  @impl true
  def request(%Request{} = request, credential, %__MODULE__{} = config) do
    with {:ok, target} <- admit(request, config),
         false <- Request.stream?(request),
         {:ok, _digest} <- Credentials.token_digest(credential),
         {:ok, deadline} <- budget(Request.deadline(request)),
         {:ok, conn} <- connect(config, request, deadline) do
      try do
        exchange(conn, request, target, credential, deadline)
      after
        HTTP.close(conn)
      end
    else
      {:error, :timeout} -> {:error, :timeout}
      {:error, %Mint.TransportError{reason: :timeout}} -> {:error, :timeout}
      _ -> {:error, :request_failed}
    end
  end

  def request(_, _, _), do: {:error, :request_failed}

  @impl true
  def subscribe(%Request{} = request, credential, owner, %__MODULE__{} = config)
      when is_pid(owner) do
    with {:ok, target} <- admit(request, config),
         true <- Request.stream?(request),
         {:ok, _} <- Credentials.token_digest(credential) do
      SSEClient.open(request, credential, owner, config, target)
    else
      _ -> {:error, :request_failed}
    end
  end

  def subscribe(_, _, _, _), do: {:error, :request_failed}

  @impl true
  def close(handle, %__MODULE__{} = config), do: SSEClient.close(handle, config)
  def close(_, _), do: {:error, :request_failed}

  defp admit(request, config) do
    uri = URI.parse(Request.uri(request))
    prefix = "/api/v1/scopes/" <> URI.encode(config.scope, &URI.char_unreserved?/1) <> "/things/"

    allowed =
      supported?(request) and destination?(uri, config) and
        is_binary(uri.path) and String.starts_with?(uri.path, prefix) and safe_headers?(request)

    if allowed and
         property_path?(String.replace_prefix(uri.path, prefix, ""), Request.stream?(request)),
       do: {:ok, uri.path},
       else: {:error, :destination_denied}
  end

  defp supported?(request),
    do:
      Request.method(request) == "GET" and
        is_nil(Request.body(request)) and
        {Request.operation(request), Request.stream?(request)} in [
          {:readproperty, false},
          {:observeproperty, true}
        ]

  defp destination?(uri, config),
    do:
      uri.scheme == "http" and uri.host == config.host and
        uri.port == config.port and is_nil(uri.query) and is_nil(uri.fragment) and
        is_nil(uri.userinfo)

  defp safe_headers?(request),
    do:
      not Enum.any?(Request.headers(request), fn {name, _} ->
        name in ["authorization", "proxy-authorization", "host", "connection"]
      end)

  defp property_path?(path, stream?) do
    case {String.split(path, "/"), stream?} do
      {[thing, "properties", name], false} when thing != "" and name != "" -> true
      {[thing, "properties", name, "observe"], true} when thing != "" and name != "" -> true
      _ -> false
    end
  end

  defp budget(deadline) do
    now = System.monotonic_time(:millisecond)
    clock = if match?(%DateTime{}, deadline), do: DateTime.utc_now(), else: now

    case Context.remaining_ms(deadline, clock) do
      :infinity -> {:ok, now + 5000}
      remaining when is_integer(remaining) and remaining > 0 -> {:ok, now + min(remaining, 5000)}
      _ -> {:error, :timeout}
    end
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp connect(config, request, deadline) do
    HTTP.connect(:http, config.ip, config.port,
      hostname: config.host,
      mode: :passive,
      log: false,
      max_header_list_size: min(Request.max_header_bytes(request), 8192),
      transport_opts: [
        timeout: remaining(deadline),
        send_timeout: remaining(deadline),
        send_timeout_close: true,
        buffer: 8192,
        recbuf: 8192
      ]
    )
  end

  defp exchange(conn, request, target, credential, deadline) do
    case remaining(deadline) do
      0 ->
        {:error, :timeout}

      timeout ->
        case :inet.setopts(HTTP.get_socket(conn), send_timeout: timeout) do
          :ok -> send_request(conn, request, target, credential, deadline)
          _ -> {:error, :request_failed}
        end
    end
  end

  defp send_request(conn, request, target, credential, deadline) do
    headers = [
      {"authorization", "Bearer " <> credential},
      {"connection", "close"} | Request.headers(request)
    ]

    case HTTP.request(conn, "GET", target, headers, nil) do
      {:ok, conn, reference} ->
        collect(conn, reference, request, deadline, %{
          status: nil,
          headers: [],
          body: [],
          bytes: 0
        })

      {:error, _, %Mint.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      _ ->
        {:error, :request_failed}
    end
  end

  defp collect(conn, reference, request, deadline, state) do
    if remaining(deadline) == 0 do
      {:error, :timeout}
    else
      receive_response(conn, reference, request, deadline, state)
    end
  end

  defp receive_response(conn, reference, request, deadline, state) do
    case HTTP.recv(conn, 0, remaining(deadline)) do
      {:ok, conn, responses} ->
        case Enum.reduce_while(responses, {:more, state}, &response(&1, &2, reference, request)) do
          {:more, state} -> collect(conn, reference, request, deadline, state)
          result -> result
        end

      {:error, _, %Mint.TransportError{reason: :timeout}, _} ->
        {:error, :timeout}

      _ ->
        {:error, :request_failed}
    end
  end

  defp response({:status, reference, status}, {:more, %{status: nil} = state}, reference, _)
       when status in 200..599,
       do: {:cont, {:more, %{state | status: status}}}

  defp response({:headers, reference, fields}, {:more, state}, reference, request) do
    fields = state.headers ++ fields

    case Headers.validate_limits(
           fields,
           min(Request.max_header_count(request), 32),
           min(Request.max_header_bytes(request), 8192),
           :response
         ) do
      :ok -> {:cont, {:more, %{state | headers: fields}}}
      _ -> {:halt, {:error, :response_rejected}}
    end
  end

  defp response({:data, reference, bytes}, {:more, state}, reference, request) do
    size = state.bytes + byte_size(bytes)

    if size <= min(Request.max_response_bytes(request), 1_048_576),
      do: {:cont, {:more, %{state | body: [bytes | state.body], bytes: size}}},
      else: {:halt, {:error, :response_rejected}}
  end

  defp response({:done, reference}, {:more, state}, reference, _) do
    body = state.body |> Enum.reverse() |> IO.iodata_to_binary()
    {:halt, Response.new(state.status, state.headers, body)}
  end

  defp response(_, _, _, _), do: {:halt, {:error, :response_rejected}}
end
