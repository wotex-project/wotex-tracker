defmodule Wotex.Tracker.Service.HTTP.PropertyStream do
  @moduledoc false
  import Plug.Conn
  alias Wotex.Tracker.Service.{Codec, PropertyObservation, Store}
  alias Wotex.Tracker.Service.HTTP.Wire

  def run(conn, service, access, page, config) do
    conn =
      conn
      |> Wire.headers()
      |> put_resp_header("x-accel-buffering", "no")
      |> put_resp_content_type("text/event-stream")
      |> send_chunked(200)

    deliver(conn, service, access, page, config)
  end

  defp deliver(conn, service, access, page, config) do
    result =
      Enum.reduce_while(page["items"], {:ok, conn}, fn item, {:ok, conn} ->
        with :ok <- Store.authorized(service.store, access, "read", config.clock.()),
             {:ok, bytes} <- Codec.encode(item["value"], 16_384),
             {:ok, conn} <-
               chunk(conn, [
                 "id: ",
                 item["cursor"],
                 "\nevent: property:",
                 item["event_id"],
                 ":",
                 item["generation"],
                 "\ndata: ",
                 bytes,
                 "\n\n"
               ]) do
          {:cont, {:ok, conn}}
        else
          _ -> {:halt, {:closed, conn}}
        end
      end)

    case result do
      {:ok, conn} ->
        if page["closed"], do: conn, else: poll(conn, service, access, page["cursor"], config)

      {:closed, conn} ->
        conn
    end
  end

  defp poll(conn, service, access, cursor, config) do
    receive do
      {:EXIT, _, _} -> conn
    after
      config.poll_interval ->
        with {:ok, page} <- PropertyObservation.batch(service, access, cursor, config.clock.()),
             :ok <- Store.authorized(service.store, access, "read", config.clock.()),
             {:ok, conn} <- chunk(conn, ": keepalive\n\n") do
          deliver(conn, service, access, page, config)
        else
          _ -> conn
        end
    end
  end
end
