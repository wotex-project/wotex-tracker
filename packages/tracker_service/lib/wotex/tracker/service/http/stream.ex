defmodule Wotex.Tracker.Service.HTTP.Stream do
  @moduledoc false
  import Plug.Conn
  alias Wotex.Tracker.Service.{Codec, Events, Store}
  alias Wotex.Tracker.Service.HTTP.Wire

  def run(conn, service, access, cursor, page, config) do
    ready = Codec.encode!(%{"schema" => "wtr.stream.v1", "cursor" => cursor})

    conn =
      conn
      |> Wire.headers()
      |> put_resp_header("x-accel-buffering", "no")
      |> put_resp_content_type("text/event-stream")
      |> send_chunked(200)

    case chunk(conn, ["event: ready\ndata: ", ready, "\n\n"]) do
      {:ok, conn} -> deliver(conn, service, access, page, config)
      {:error, _} -> conn
    end
  end

  defp deliver(conn, service, access, page, config) do
    result =
      Enum.reduce_while(page["items"], {:ok, conn}, fn event, {:ok, conn} ->
        with :ok <- Store.authorized(service.store, access, "read", config.clock.()),
             {:ok, bytes} <- Codec.encode(event, 32_768),
             {:ok, conn} <-
               chunk(conn, ["id: ", event["cursor"], "\nevent: tracker\ndata: ", bytes, "\n\n"]) do
          {:cont, {:ok, conn}}
        else
          _ -> {:halt, {:closed, conn}}
        end
      end)

    case result do
      {:ok, conn} -> poll(conn, service, access, page["cursor"], config)
      {:closed, conn} -> conn
    end
  end

  defp poll(conn, service, access, cursor, config) do
    receive do
      # Parent shutdown is not a reason to retain this connection for its lifetime.
      {:EXIT, _, _} -> conn
    after
      config.poll_interval ->
        with {:ok, page} <- Events.batch(service, access, cursor, config.clock.()),
             :ok <- Store.authorized(service.store, access, "read", config.clock.()),
             {:ok, conn} <- chunk(conn, ": keepalive\n\n") do
          deliver(conn, service, access, page, config)
        else
          _ -> conn
        end
    end
  end
end
