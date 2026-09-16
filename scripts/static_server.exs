defmodule Wotex.Tracker.StaticServer do
  @moduledoc false

  def start_link(root, port \\ 0) do
    root = Path.expand(root)

    {:ok, listener} =
      :gen_tcp.listen(port, [
        :binary,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1},
        packet: :raw
      ])

    {:ok, {{127, 0, 0, 1}, actual_port}} = :inet.sockname(listener)

    pid =
      spawn(fn ->
        receive do
          {:listen, socket} -> accept(socket, root)
        end
      end)

    :ok = :gen_tcp.controlling_process(listener, pid)
    send(pid, {:listen, listener})
    {:ok, pid, actual_port}
  end

  defp accept(listener, root) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        spawn(fn -> serve(socket, root) end)
        accept(listener, root)

      {:error, :closed} ->
        :ok
    end
  end

  defp serve(socket, root) do
    response =
      with {:ok, request} <- receive_request(socket, <<>>),
           {:ok, method, target} <- parse_request(request),
           {:ok, path} <- admitted_path(root, target),
           {:ok, bytes} <- File.read(path) do
        body = if method == "HEAD", do: <<>>, else: bytes

        [
          "HTTP/1.1 200 OK\r\n",
          "Content-Type: application/octet-stream\r\n",
          "Content-Length: ",
          Integer.to_string(byte_size(bytes)),
          "\r\nConnection: close\r\n\r\n",
          body
        ]
      else
        _ ->
          "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
      end

    :gen_tcp.send(socket, response)
    :gen_tcp.close(socket)
  end

  defp receive_request(_socket, bytes) when byte_size(bytes) > 16_384,
    do: {:error, :request_too_large}

  defp receive_request(socket, bytes) do
    if :binary.match(bytes, "\r\n\r\n") == :nomatch do
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, chunk} -> receive_request(socket, bytes <> chunk)
        error -> error
      end
    else
      {:ok, bytes}
    end
  end

  defp parse_request(request) do
    with [line | _headers] <- String.split(request, "\r\n"),
         [method, target, "HTTP/1.1"] <- String.split(line, " "),
         true <- method in ["GET", "HEAD"] do
      {:ok, method, target}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp admitted_path(root, target) do
    decoded = target |> String.split("?", parts: 2) |> hd() |> URI.decode()
    relative = String.trim_leading(decoded, "/")
    path = Path.expand(relative, root)

    if String.starts_with?(path, root <> "/") and File.regular?(path),
      do: {:ok, path},
      else: {:error, :not_found}
  end
end

unless System.get_env("WOTEX_TRACKER_STATIC_SERVER_NO_MAIN") == "1" do
  case System.argv() do
    [root, port] ->
      {:ok, _pid, actual_port} =
        Wotex.Tracker.StaticServer.start_link(root, String.to_integer(port))

      IO.puts("STATIC_SERVER_READY #{actual_port}")
      Process.sleep(:infinity)

    _ ->
      raise("usage: static_server.exs ROOT PORT")
  end
end
