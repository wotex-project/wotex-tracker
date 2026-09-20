defmodule Wotex.Tracker.Nerves.Browser.DeviceSession do
  @moduledoc """
  Issues one authenticated, single-use launch URL to the attached kiosk.

  The private service credential is read only while creating or renewing the
  server-held browser session. Cog receives a random nonce, never the bearer or
  the opaque session identifier. Exchanging that nonce reauthorizes the session
  through the service and consumes it even when authorization fails.
  """

  use GenServer
  alias Wotex.Tracker.Service.{Codec, Credentials}
  alias Wotex.Tracker.UI.Sessions

  @nonce_ttl_ms 60_000

  @doc "Starts the local-display session issuer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) when is_list(options) do
    {name, options} = Keyword.pop(options, :name, __MODULE__)

    with true <- Keyword.keyword?(options),
         {:ok, state} <- configuration(options) do
      GenServer.start_link(__MODULE__, state, name: name)
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  def start_link(_), do: {:error, :invalid_configuration}

  @doc "Returns a launch URL containing only a short-lived single-use nonce."
  @spec launch_url(String.t()) :: String.t()
  def launch_url(origin), do: launch_url(origin, __MODULE__)

  @spec launch_url(String.t(), GenServer.server()) :: String.t()
  def launch_url(origin, server) when is_binary(origin) do
    GenServer.call(server, :launch_url)
  catch
    :exit, _ -> origin
  end

  @doc "Consumes a launch nonce and returns the already-authenticated opaque session."
  @spec exchange(term()) :: {:ok, String.t()} | {:error, :unauthorized}
  def exchange(nonce), do: exchange(__MODULE__, nonce)

  @spec exchange(GenServer.server(), term()) :: {:ok, String.t()} | {:error, :unauthorized}
  def exchange(server, nonce) do
    GenServer.call(server, {:exchange, nonce})
  catch
    :exit, _ -> {:error, :unauthorized}
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:launch_url, _from, state) do
    case ensure_session(state) do
      {:ok, state} -> issue_nonce(state)
      {:error, state} -> {:reply, state.origin, clear_nonce(state)}
    end
  end

  def handle_call({:exchange, nonce}, _from, state) do
    now = state.monotonic.()
    valid? = valid_nonce?(nonce, state.nonce) and now < state.nonce_expires_at
    state = clear_nonce(state)

    if valid? do
      case Sessions.request(state.sessions, state.session, :authorize) do
        {:ok, _context} -> {:reply, {:ok, state.session}, state}
        _ -> {:reply, {:error, :unauthorized}, %{state | session: nil}}
      end
    else
      {:reply, {:error, :unauthorized}, state}
    end
  end

  defp configuration(options) do
    sessions = options[:sessions]
    token_file = options[:token_file]
    scope = options[:scope]
    origin = options[:public_origin]
    monotonic = Keyword.get(options, :monotonic, fn -> System.monotonic_time(:millisecond) end)

    valid_keys? =
      Keyword.keys(options) |> Enum.sort() ==
        Enum.sort([:sessions, :token_file, :scope, :public_origin] ++ optional_monotonic(options))

    if valid_keys? and server?(sessions) and private_path?(token_file) and Codec.id?(scope) and
         loopback_origin?(origin) and is_function(monotonic, 0) do
      {:ok,
       %{
         sessions: sessions,
         token_file: token_file,
         scope: scope,
         origin: origin,
         monotonic: monotonic,
         session: nil,
         nonce: nil,
         nonce_expires_at: 0
       }}
    else
      {:error, :invalid_configuration}
    end
  end

  defp optional_monotonic(options),
    do: if(Keyword.has_key?(options, :monotonic), do: [:monotonic], else: [])

  defp server?(value) when is_pid(value), do: true
  defp server?(value) when is_atom(value), do: value not in [nil, true, false]
  defp server?({:global, _name}), do: true
  defp server?({:via, module, _name}), do: is_atom(module)
  defp server?(_), do: false

  defp private_path?(path) when is_binary(path),
    do: Path.type(path) == :absolute and Path.expand(path) == path

  defp private_path?(_), do: false

  defp loopback_origin?(origin) do
    case URI.new(origin) do
      {:ok,
       %URI{
         scheme: "http",
         host: host,
         port: port,
         path: path,
         userinfo: nil,
         query: nil,
         fragment: nil
       }}
      when host in ["127.0.0.1", "localhost"] and port in 1..65_535 and path in [nil, ""] ->
        true

      _ ->
        false
    end
  end

  defp ensure_session(%{session: session} = state) when is_binary(session) do
    case Sessions.request(state.sessions, session, :authorize) do
      {:ok, _context} -> {:ok, state}
      _ -> login(%{state | session: nil})
    end
  end

  defp ensure_session(state), do: login(state)

  defp login(state) do
    with {:ok, token} <- read_token(state.token_file),
         {:ok, %{"id" => session}} <- Sessions.login(state.sessions, token, state.scope) do
      {:ok, %{state | session: session}}
    else
      _ -> {:error, %{state | session: nil}}
    end
  end

  defp read_token(path) do
    with {:ok, <<token::binary-size(43), "\n">>} <-
           File.open(path, [:read, :binary], &IO.binread(&1, 45)),
         {:ok, _digest} <- Credentials.token_digest(token) do
      {:ok, token}
    else
      _ -> {:error, :unavailable}
    end
  end

  defp issue_nonce(state) do
    nonce = Credentials.generate_token()
    expires_at = state.monotonic.() + @nonce_ttl_ms
    url = state.origin <> "/device-session?nonce=" <> nonce
    {:reply, url, %{state | nonce: nonce, nonce_expires_at: expires_at}}
  end

  defp valid_nonce?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: :crypto.hash_equals(left, right)

  defp valid_nonce?(_, _), do: false

  defp clear_nonce(state), do: %{state | nonce: nil, nonce_expires_at: 0}
end
