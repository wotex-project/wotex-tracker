defmodule Wotex.Tracker.Mobile.SessionGate do
  @moduledoc """
  Establishes and verifies the ephemeral native app-session capability.

  The capability appears only in the one initial loopback bootstrap request.
  Subsequent HTTP and LiveView admission uses its digest inside the encrypted,
  signed, HTTP-only session cookie.
  """

  @behaviour Plug
  import Plug.Conn

  @session_key "mobile_capability"
  @maximum_capability_bytes 128

  @impl Plug
  def init(options), do: options

  @impl Plug
  def call(conn, _options) do
    mobile = Phoenix.Controller.endpoint_module(conn).config(:mobile)
    digest = mobile[:capability_digest]
    conn = fetch_session(conn)

    case {conn.method, conn.path_info} do
      {"GET", ["_mobile", "bootstrap", capability]} ->
        bootstrap(conn, digest, capability, mobile[:session_provider])

      _ ->
        admit(conn, digest)
    end
  end

  def valid_session?(digest, session) when is_map(session) do
    secure_equal?(session[@session_key], digest)
  end

  def valid_session?(_, _), do: false

  def retained_session(digest, session) do
    if valid_session?(digest, session), do: %{@session_key => digest}, else: %{}
  end

  defp bootstrap(conn, digest, capability, provider) do
    candidate =
      if byte_size(capability) in 1..@maximum_capability_bytes,
        do: :crypto.hash(:sha256, capability),
        else: <<>>

    if secure_equal?(candidate, digest) do
      conn
      |> configure_session(renew: true)
      |> put_session(@session_key, digest)
      |> put_browser_session(provider)
      |> put_resp_header("cache-control", "no-store")
      |> Phoenix.Controller.redirect(to: "/sign-in")
      |> halt()
    else
      reject(conn, :not_found)
    end
  end

  defp admit(conn, digest) do
    if valid_session?(digest, get_session(conn)),
      do: conn,
      else: reject(conn, :unauthorized)
  end

  defp reject(conn, status) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, "")
    |> halt()
  end

  defp secure_equal?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: Plug.Crypto.secure_compare(left, right)

  defp secure_equal?(_, _), do: false

  defp put_browser_session(conn, {module, context}) when is_atom(module) do
    case module.browser_session(context) do
      {:ok, id} when is_binary(id) ->
        if canonical_session_id?(id), do: put_session(conn, "browser_session", id), else: conn

      _ ->
        conn
    end
  rescue
    _ -> conn
  catch
    _, _ -> conn
  end

  defp put_browser_session(conn, _), do: conn

  defp canonical_session_id?(id) do
    case Base.url_decode64(id, padding: false) do
      {:ok, decoded} ->
        byte_size(decoded) == 32 and Base.url_encode64(decoded, padding: false) == id

      :error ->
        false
    end
  end
end
