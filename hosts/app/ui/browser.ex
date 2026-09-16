defmodule Wotex.Tracker.Host.Browser do
  @moduledoc """
  Supervises the standalone host's optional browser presentation.

  A UI-enabled artifact includes this module and the shared LiveView package.
  It starts PubSub, bounded server-held sessions, the endpoint, render
  telemetry, and an optional host-owned prompt provider. The service remains
  authoritative; this supervisor owns no second observation store.
  """

  use Supervisor
  alias Wotex.Tracker.Host.Browser.{Client, Endpoint}
  alias Wotex.Tracker.Host.Browser.PromptProvider
  alias Wotex.Tracker.Host.Browser.RenderTelemetry
  alias Wotex.Tracker.UI.Sessions

  @doc false
  def start_link(options), do: Supervisor.start_link(__MODULE__, options)

  @impl true
  def init({config, provider, server_provider}) do
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
        tracker_ui: [
          sessions: Wotex.Tracker.Host.Browser.Sessions,
          prompt:
            if(config.prompt,
              do: {PromptProvider, Wotex.Tracker.Host.Browser.PromptProvider},
              else: nil
            ),
          operational_history: true
        ],
        debug_errors: false,
        code_reloader: false
      ]
      |> Keyword.put(transport, listener)

    prompt =
      if config.prompt do
        [
          {Task.Supervisor, name: Wotex.Tracker.Host.Browser.PromptTasks},
          {PromptProvider,
           name: Wotex.Tracker.Host.Browser.PromptProvider,
           task_supervisor: Wotex.Tracker.Host.Browser.PromptTasks,
           config: config.prompt}
        ]
      else
        []
      end

    Supervisor.init(
      [
        {Phoenix.PubSub, name: Wotex.Tracker.Host.Browser.PubSub},
        {Sessions,
         name: Wotex.Tracker.Host.Browser.Sessions, client: {Client, {provider, server_provider}}}
      ] ++
        prompt ++
        [
          {RenderTelemetry, []},
          {Endpoint, endpoint}
        ],
      strategy: :rest_for_one
    )
  end
end
