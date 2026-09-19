defmodule Wotex.Tracker.Mobile.Host do
  @moduledoc """
  Supervises the loopback presentation host for the native mobile shell.

  The tree owns only its cache, volatile credential sessions, PubSub, runtime
  WebView target and loopback endpoint. The remote service stays authoritative.
  """

  use Supervisor
  alias Wotex.Tracker.Mobile.{Cache, Config, CredentialManager, Endpoint, Runtime, SessionGate}
  alias Wotex.Tracker.UI.{Remote, Sessions}

  @pubsub Wotex.Tracker.Mobile.PubSub
  @sessions Wotex.Tracker.Mobile.Sessions
  @cache Wotex.Tracker.Mobile.CacheServer
  @credentials Wotex.Tracker.Mobile.CredentialManager

  @doc "Starts one explicit local mobile composition."
  @spec start_link(keyword() | Config.t()) :: Supervisor.on_start()
  def start_link(%Config{} = config) do
    Supervisor.start_link(__MODULE__, config, name: Wotex.Tracker.Mobile.Supervisor)
  end

  def start_link(options) when is_list(options) do
    case Config.new(options) do
      {:ok, config} -> start_link(config)
      {:error, reason} -> {:error, reason}
    end
  end

  def start_link(_), do: {:error, :invalid_configuration}

  @impl true
  def init(%Config{} = config), do: children(config)

  defp children(config) do
    listener = [
      ip: {127, 0, 0, 1},
      port: config.port,
      http_1_options: [
        max_request_line_length: 8_192,
        max_header_length: 8_192,
        max_header_count: 32
      ],
      http_2_options: [enabled: false],
      websocket_options: [max_frame_size: 65_536],
      thousand_island_options: [
        num_acceptors: 2,
        num_connections: 8,
        max_connections_retry_count: 0,
        read_timeout: 60_000
      ]
    ]

    endpoint = [
      server: true,
      adapter: Bandit.PhoenixAdapter,
      secret_key_base: config.secret_key_base,
      url: [scheme: "http", host: "127.0.0.1", port: config.port],
      check_origin: [config.origin],
      pubsub_server: @pubsub,
      live_view: [signing_salt: "tracker-mobile-live-v1"],
      render_errors: [formats: [html: Wotex.Tracker.UI.ErrorHTML], layout: false],
      tracker_ui: [
        sessions: @sessions,
        session_guard: {SessionGate, config.capability_digest},
        prompt: nil,
        operational_history: false
      ],
      mobile: [
        capability_digest: config.capability_digest,
        session_provider: {CredentialManager, @credentials}
      ],
      debug_errors: false,
      code_reloader: false,
      http: listener
    ]

    Supervisor.init(
      [
        {Cache, directory: config.directory, name: @cache},
        {Phoenix.PubSub, name: @pubsub},
        {Sessions,
         name: @sessions,
         client: {Remote, config.remote},
         capacity: 1,
         custodian: {CredentialManager, @credentials}},
        {CredentialManager,
         name: @credentials,
         sessions: @sessions,
         cache: @cache,
         origin: config.remote_origin,
         secure_store: config.secure_store,
         clock: config.clock},
        {Runtime, config.web_session},
        {Endpoint, endpoint}
      ],
      strategy: :rest_for_one
    )
  end
end
