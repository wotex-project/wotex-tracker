defmodule Wotex.Tracker.Service.APNsMintTransport do
  @moduledoc false

  @behaviour Wotex.Tracker.Service.APNsTransport

  @maximum_body_bytes 4_096
  @maximum_header_bytes 8_192
  @maximum_headers 32

  @impl true
  def request(client, request) do
    client = client || Mint.HTTP2

    if request?(request) and client?(client) do
      execute(client, request)
    else
      {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp execute(client, request) do
    deadline = System.monotonic_time(:millisecond) + request.timeout_ms

    options = [
      mode: :passive,
      log: false,
      client_settings: [enable_push: false],
      transport_opts: [
        timeout: remaining(deadline),
        send_timeout: remaining(deadline),
        send_timeout_close: true
      ]
    ]

    case client.connect(:https, request.host, 443, options) do
      {:ok, connection} -> exchange(client, connection, request, deadline)
      {:error, error} -> transport_error(error)
      _ -> {:error, :unavailable}
    end
  end

  defp exchange(client, connection, request, deadline) do
    case client.request(
           connection,
           "POST",
           request.path,
           request.headers,
           request.body
         ) do
      {:ok, connection, reference} ->
        receive_response(client, connection, reference, deadline, %{
          status: nil,
          headers: [],
          body: [],
          body_bytes: 0
        })

      {:error, _connection, error} ->
        transport_error(error)

      _ ->
        {:error, :unavailable}
    end
  after
    close(client, connection)
  end

  defp receive_response(client, connection, reference, deadline, state) do
    case remaining(deadline) do
      0 ->
        {:error, :timeout}

      timeout ->
        case client.recv(connection, 0, timeout) do
          {:ok, connection, responses} ->
            continue(client, connection, reference, deadline, responses, state)

          {:error, _connection, error, _responses} ->
            transport_error(error)

          _ ->
            {:error, :unavailable}
        end
    end
  end

  defp continue(client, connection, reference, deadline, responses, state) do
    case Enum.reduce_while(responses, {:more, state}, &response(&1, &2, reference)) do
      {:more, state} -> receive_response(client, connection, reference, deadline, state)
      {:done, response} -> response
      {:error, reason} -> {:error, reason}
    end
  end

  defp response({:status, reference, status}, {:more, %{status: nil} = state}, reference)
       when status in 100..599,
       do: {:cont, {:more, %{state | status: status}}}

  defp response({:headers, reference, fields}, {:more, state}, reference) do
    headers = state.headers ++ fields

    if headers?(headers),
      do: {:cont, {:more, %{state | headers: headers}}},
      else: {:halt, {:error, :response_rejected}}
  end

  defp response({:data, reference, bytes}, {:more, state}, reference)
       when is_binary(bytes) do
    size = state.body_bytes + byte_size(bytes)

    if size <= @maximum_body_bytes,
      do: {:cont, {:more, %{state | body: [bytes | state.body], body_bytes: size}}},
      else: {:halt, {:error, :response_rejected}}
  end

  defp response({:done, reference}, {:more, %{status: status} = state}, reference)
       when is_integer(status) do
    body = state.body |> Enum.reverse() |> IO.iodata_to_binary()
    {:halt, {:done, {:ok, status, state.headers, body}}}
  end

  defp response({:error, reference, _error}, {:more, _state}, reference),
    do: {:halt, {:error, :unavailable}}

  defp response(_, _, _), do: {:halt, {:error, :response_rejected}}

  defp request?(%{
         host: host,
         path: path,
         headers: headers,
         body: body,
         timeout_ms: timeout
       }) do
    is_binary(host) and host in ["api.sandbox.push.apple.com", "api.push.apple.com"] and
      is_binary(path) and String.starts_with?(path, "/3/device/") and headers?(headers) and
      is_binary(body) and byte_size(body) in 1..@maximum_body_bytes and
      is_integer(timeout) and timeout in 1..30_000
  end

  defp request?(_), do: false

  defp headers?(headers) when is_list(headers) and length(headers) <= @maximum_headers do
    Enum.all?(headers, fn
      {name, value} when is_binary(name) and is_binary(value) ->
        byte_size(name) + byte_size(value) <= @maximum_header_bytes

      _ ->
        false
    end) and
      Enum.reduce(headers, 0, fn {name, value}, total ->
        total + byte_size(name) + byte_size(value)
      end) <= @maximum_header_bytes
  end

  defp headers?(_), do: false

  defp client?(client),
    do:
      is_atom(client) and function_exported?(client, :connect, 4) and
        function_exported?(client, :request, 5) and function_exported?(client, :recv, 3) and
        function_exported?(client, :close, 1)

  defp transport_error(%Mint.TransportError{reason: :timeout}), do: {:error, :timeout}
  defp transport_error(%Mint.HTTPError{reason: :timeout}), do: {:error, :timeout}
  defp transport_error(:timeout), do: {:error, :timeout}
  defp transport_error(_), do: {:error, :unavailable}

  defp close(client, connection) do
    _ = client.close(connection)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp remaining(deadline),
    do: max(deadline - System.monotonic_time(:millisecond), 0)
end
