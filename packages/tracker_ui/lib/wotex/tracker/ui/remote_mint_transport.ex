defmodule Wotex.Tracker.UI.RemoteMintTransport do
  @moduledoc false

  @behaviour Wotex.Tracker.UI.RemoteTransport

  @maximum_request_bytes 1_048_576
  @maximum_response_bytes 4_194_304
  @maximum_header_bytes 16_384
  @maximum_headers 64

  @impl true
  def request(context, origin, request) do
    {client, certificates} = context || {Mint.HTTP, &:public_key.cacerts_get/0}

    if client?(client) and is_function(certificates, 0) and origin?(origin) and request?(request) do
      execute(client, certificates, origin, request)
    else
      {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp execute(client, certificates, origin, request) do
    deadline = System.monotonic_time(:millisecond) + request.timeout_ms

    with {:ok, options} <- options(origin, certificates, deadline) do
      case client.connect(origin.scheme, origin.host, origin.port, options) do
        {:ok, connection} -> exchange(client, connection, request, deadline)
        {:error, error} -> transport_error(error)
        _ -> {:error, :unavailable}
      end
    end
  end

  defp options(%{scheme: :https, host: host}, certificates, deadline) do
    case certificates.() do
      certificates when is_list(certificates) and certificates != [] ->
        {:ok,
         [
           mode: :passive,
           log: false,
           protocols: [:http1],
           transport_opts: [
             verify: :verify_peer,
             cacerts: certificates,
             server_name_indication: String.to_charlist(host),
             customize_hostname_check: [
               match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
             ],
             timeout: remaining(deadline),
             send_timeout: remaining(deadline),
             send_timeout_close: true
           ]
         ]}

      _ ->
        {:error, :unavailable}
    end
  end

  defp options(%{scheme: :http}, _, deadline) do
    {:ok,
     [
       mode: :passive,
       log: false,
       protocols: [:http1],
       transport_opts: [
         timeout: remaining(deadline),
         send_timeout: remaining(deadline),
         send_timeout_close: true
       ]
     ]}
  end

  defp exchange(client, connection, request, deadline) do
    case client.request(
           connection,
           request.method,
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

          {:error, _connection, error, responses} ->
            finish_or_error(responses, state, reference, error)

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

  defp finish_or_error(responses, state, reference, error) do
    case Enum.reduce_while(responses, {:more, state}, &response(&1, &2, reference)) do
      {:done, response} -> response
      {:more, _state} -> transport_error(error)
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

  defp response({:data, reference, bytes}, {:more, state}, reference) when is_binary(bytes) do
    size = state.body_bytes + byte_size(bytes)

    if size <= @maximum_response_bytes,
      do: {:cont, {:more, %{state | body: [bytes | state.body], body_bytes: size}}},
      else: {:halt, {:error, :response_rejected}}
  end

  defp response({:done, reference}, {:more, %{status: status} = state}, reference)
       when is_integer(status) do
    body = state.body |> Enum.reverse() |> IO.iodata_to_binary()
    {:halt, {:done, {:ok, status, state.headers, body}}}
  end

  defp response({:error, reference, error}, {:more, _state}, reference),
    do: {:halt, transport_error(error)}

  defp response(_, _, _), do: {:halt, {:error, :response_rejected}}

  defp origin?(%{scheme: scheme, host: host, port: port} = origin)
       when map_size(origin) == 3,
       do:
         scheme in [:http, :https] and is_binary(host) and byte_size(host) in 1..253 and
           port in 1..65_535

  defp origin?(_), do: false

  defp request?(
         %{
           method: method,
           path: path,
           headers: headers,
           body: body,
           timeout_ms: timeout
         } = request
       )
       when map_size(request) == 5 do
    method in ["GET", "POST"] and is_binary(path) and byte_size(path) in 1..16_384 and
      String.starts_with?(path, "/api/v1/scopes/") and headers?(headers) and is_binary(body) and
      byte_size(body) <= @maximum_request_bytes and is_integer(timeout) and timeout in 100..30_000
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
      is_atom(client) and Code.ensure_loaded?(client) and function_exported?(client, :connect, 4) and
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

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
