defmodule Wotex.Tracker.Nerves.Browser.DeviceSessionPlug do
  @moduledoc false

  import Plug.Conn
  alias Wotex.Tracker.Nerves.Browser.DeviceSession

  @path "/device-session"

  def init(options), do: options

  def call(%{method: "GET", request_path: @path} = conn, _options) do
    conn = fetch_query_params(conn)

    with true <- loopback?(conn.remote_ip),
         nonce when is_binary(nonce) <- conn.query_params["nonce"],
         true <- byte_size(nonce) == 43,
         {:ok, session} <- DeviceSession.exchange(nonce) do
      conn
      |> fetch_session()
      |> clear_session()
      |> configure_session(renew: true)
      |> put_session(:browser_session, session)
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("location", "/setup")
      |> send_resp(303, "See Other\n")
      |> halt()
    else
      _ -> not_found(conn)
    end
  end

  def call(conn, _options), do: conn

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_), do: false

  defp not_found(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(404, "Not found\n")
    |> halt()
  end
end
