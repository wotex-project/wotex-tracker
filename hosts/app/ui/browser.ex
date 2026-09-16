defmodule Wotex.Tracker.Host.Browser do
  @moduledoc "Optional browser composition; only a UI-enabled artifact compiles this host."
  use Supervisor
  alias Wotex.Tracker.Host.Browser.Endpoint
  alias Wotex.Tracker.UI.{Local, Sessions}

  @doc false
  def start_link(options), do: Supervisor.start_link(__MODULE__, options)

  @impl true
  def init({config, provider}) do
    uri = URI.parse(config.public_origin)
    transport = if config.exposure == :tls, do: :https, else: :http

    listener = [
      ip: config.ip,
      port: config.port,
      http_1_options: [
        max_request_line_length: 8192,
        max_header_length: 8192,
        max_header_count: 32
      ],
      http_2_options: [enabled: false],
      websocket_options: [max_frame_size: 65_536],
      thousand_island_options: [
        num_acceptors: 4,
        num_connections: 16,
        max_connections_retry_count: 0,
        read_timeout: 60_000
      ]
    ]

    listener = if config.tls, do: Keyword.merge(listener, Map.to_list(config.tls)), else: listener

    endpoint =
      [
        server: true,
        adapter: Bandit.PhoenixAdapter,
        secret_key_base: config.secret_key_base,
        url: [scheme: uri.scheme, host: uri.host, port: uri.port],
        check_origin: [config.public_origin],
        pubsub_server: Wotex.Tracker.Host.Browser.PubSub,
        live_view: [signing_salt: "tracker-live-v1"],
        render_errors: [formats: [html: Wotex.Tracker.UI.ErrorHTML], layout: false],
        tracker_ui: [sessions: Wotex.Tracker.Host.Browser.Sessions],
        debug_errors: false,
        code_reloader: false
      ]
      |> Keyword.put(transport, listener)

    Supervisor.init(
      [
        {Phoenix.PubSub, name: Wotex.Tracker.Host.Browser.PubSub},
        {Sessions, name: Wotex.Tracker.Host.Browser.Sessions, client: {Local, provider}},
        {Endpoint, endpoint}
      ],
      strategy: :rest_for_one
    )
  end
end
