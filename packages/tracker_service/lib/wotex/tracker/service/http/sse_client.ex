defmodule Wotex.Tracker.Service.HTTP.SSEClient do
  @moduledoc false

  alias Mint.HTTP1, as: HTTP
  alias Wotex.Binding.HTTP.{Headers, Request, Response}
  alias Wotex.Runtime.Context
  alias Wotex.Tracker.Service.HTTP.{SSEConnection, SSEGuard}

  def open(request, credential, owner, config, target) do
    with {:ok, lifetime} <- budget(Request.deadline(request)),
         handshake = min(lifetime, System.monotonic_time(:millisecond) + 5000),
         {:ok, guard} <- SSEGuard.start(owner, handshake) do
      try do
        connect(request, credential, config, target, {owner, guard, handshake, lifetime})
      after
        SSEGuard.stop(guard)
      end
    end
  end

  def close({SSEConnection, handle, origin, scope}, %{origin: origin, scope: scope}),
    do: SSEConnection.close(handle)

  def close(_, _), do: {:error, :request_failed}

  defp budget(deadline) do
    now = System.monotonic_time(:millisecond)
    clock = if match?(%DateTime{}, deadline), do: DateTime.utc_now(), else: now

    case Context.remaining_ms(deadline, clock) do
      :infinity ->
        {:ok, now + 300_000}

      remaining when is_integer(remaining) and remaining > 0 ->
        {:ok, now + min(remaining, 300_000)}

      _ ->
        {:error, :timeout}
    end
  end

  defp connect(
         request,
         credential,
         config,
         target,
         {_owner, _guard, deadline, _lifetime} = lifecycle
       ) do
    options = [
      hostname: config.host,
      mode: :passive,
      log: false,
      max_header_list_size: min(Request.max_header_bytes(request), 8192),
      transport_opts: [
        timeout: min(remaining(deadline), 100),
        send_timeout: remaining(deadline),
        send_timeout_close: true,
        buffer: 8192,
        recbuf: 8192
      ]
    ]

    case HTTP.connect(:http, config.ip, config.port, options) do
      {:ok, conn} -> exchange(conn, request, credential, config, target, lifecycle)
      _ -> failure(deadline)
    end
  end

  defp exchange(conn, request, credential, config, target, {owner, guard, deadline, lifetime}) do
    result =
      with :ok <- SSEGuard.attach(guard, HTTP.get_socket(conn)),
           true <- Process.alive?(owner) and remaining(deadline) > 0,
           :ok <- :inet.setopts(HTTP.get_socket(conn), send_timeout: remaining(deadline)),
           {:ok, conn, reference} <-
             HTTP.request(
               conn,
               "GET",
               target,
               [
                 {"authorization", "Bearer " <> credential},
                 {"connection", "close"} | Request.headers(request)
               ],
               nil
             ),
           {:ok, conn, response, pending} <- headers(conn, reference, request, deadline, nil),
           {:ok, handle} <-
             transfer(conn, reference, pending, owner, lifetime, Request.max_event_bytes(request)) do
        {:ok, {SSEConnection, handle, config.origin, config.scope}, response}
      else
        _ ->
          HTTP.close(conn)
          failure(deadline)
      end

    result
  rescue
    _ ->
      HTTP.close(conn)
      {:error, :request_failed}
  catch
    :exit, _ ->
      HTTP.close(conn)
      {:error, :request_failed}
  end

  defp headers(conn, reference, request, deadline, status) do
    if remaining(deadline) == 0 do
      {:error, :timeout}
    else
      case HTTP.recv(conn, 0, remaining(deadline)) do
        {:ok, conn, responses} ->
          inspect_headers(responses, conn, reference, request, deadline, status)

        _ ->
          failure(deadline)
      end
    end
  end

  defp inspect_headers([], conn, reference, request, deadline, status),
    do: headers(conn, reference, request, deadline, status)

  defp inspect_headers(
         [{:status, reference, 200} | rest],
         conn,
         reference,
         request,
         deadline,
         nil
       ),
       do: inspect_headers(rest, conn, reference, request, deadline, 200)

  defp inspect_headers([{:headers, reference, fields} | rest], conn, reference, request, _, 200) do
    with :ok <-
           Headers.validate_limits(
             fields,
             min(Request.max_header_count(request), 32),
             min(Request.max_header_bytes(request), 8192),
             :response
           ),
         true <- media?(fields),
         {:ok, response} <- Response.new(200, fields, "") do
      {:ok, conn, response, rest}
    else
      _ -> {:error, :request_failed}
    end
  end

  defp inspect_headers(_, _, _, _, _, _), do: {:error, :request_failed}

  defp media?(fields) do
    types = for {"content-type", value} <- fields, do: value
    encodings = for {"content-encoding", value} <- fields, do: value

    case {types, encodings} do
      {[media], encoding} when encoding in [[], ["identity"]] ->
        media |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase() ==
          "text/event-stream"

      _ ->
        false
    end
  end

  defp transfer(conn, reference, pending, owner, lifetime, limit) do
    with {:ok, handle} <- SSEConnection.start(owner, lifetime, limit) do
      {pid, _} = handle

      case HTTP.controlling_process(conn, pid) do
        {:ok, conn} ->
          activate(handle, conn, reference, pending)

        _ ->
          SSEConnection.close(handle)
          {:error, :request_failed}
      end
    end
  end

  defp activate(handle, conn, reference, pending) do
    case SSEConnection.activate(handle, conn, reference, pending) do
      :ok ->
        {:ok, handle}

      _ ->
        SSEConnection.close(handle)
        {:error, :request_failed}
    end
  catch
    :exit, _ ->
      SSEConnection.close(handle)
      {:error, :request_failed}
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp failure(deadline),
    do: {:error, if(remaining(deadline) == 0, do: :timeout, else: :request_failed)}
end
