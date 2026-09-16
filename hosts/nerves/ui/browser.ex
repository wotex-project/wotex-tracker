defmodule Wotex.Tracker.Nerves.Browser do
  @moduledoc """
  Supervises the Pi control panel's loopback browser endpoint.

  This optional Nerves profile reuses `Wotex.Tracker.UI.Router` and its shared
  LiveViews. The host owns PubSub, server-held sessions, listener bounds, and
  origin checks. It binds to loopback and delegates all Tracker data requests
  to the authorized service; stopping the panel leaves ingestion running.
  """

  use Supervisor
  alias Wotex.Tracker.Nerves.Browser.{Client, Endpoint}
  alias Wotex.Tracker.UI.Sessions

  def start_link(options), do: Supervisor.start_link(__MODULE__, options)

  @impl true
  def init({config, service_provider, server_provider}) do
    uri = URI.parse(config.public_origin)

    endpoint = [
      server: true,
      adapter: Bandit.PhoenixAdapter,
      secret_key_base: config.secret_key_base,
      url: [scheme: "http", host: uri.host, port: uri.port],
      check_origin: [config.public_origin],
      pubsub_server: Wotex.Tracker.Nerves.Browser.PubSub,
      live_view: [signing_salt: "tracker-pi-live-v1"],
      render_errors: [formats: [html: Wotex.Tracker.UI.ErrorHTML], layout: false],
      tracker_ui: [
        sessions: Wotex.Tracker.Nerves.Browser.Sessions,
        prompt: nil,
        operational_history: true
      ],
      debug_errors: false,
      code_reloader: false,
      http: [
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
    ]

    Supervisor.init(
      [
        {Phoenix.PubSub, name: Wotex.Tracker.Nerves.Browser.PubSub},
        {Sessions,
         name: Wotex.Tracker.Nerves.Browser.Sessions,
         client: {Client, {service_provider, server_provider}}},
        {Endpoint, endpoint}
      ],
      strategy: :rest_for_one
    )
  end
end
