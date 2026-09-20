defmodule Wotex.Tracker.Host.Browser.RenderTelemetry do
  @moduledoc """
  Records bounded host operational samples for shared LiveView renders and
  browser reconnects.

  The process attaches to listed Phoenix events and records duration and outcome
  through `Wotex.Tracker.Service.OperationalTelemetry`. It accepts only known
  Tracker views for renders and only explicitly marked reconnect attempts for
  this endpoint. It ignores component renders and detaches its handler on
  termination. Samples contain no rendered page, socket parameters or credential.
  """

  use GenServer

  alias Wotex.Tracker.Host.Browser.Endpoint
  alias Wotex.Tracker.Service.OperationalTelemetry

  @handler {__MODULE__, :browser}
  @render_events [
    [:phoenix, :live_view, :render, :stop],
    [:phoenix, :live_view, :render, :exception]
  ]
  @connection_event [:phoenix, :socket_connected]
  @views [
    Wotex.Tracker.UI.AccessLive,
    Wotex.Tracker.UI.ActivityLive,
    Wotex.Tracker.UI.AlertIndexLive,
    Wotex.Tracker.UI.AlertLive,
    Wotex.Tracker.UI.AnalyticsLive,
    Wotex.Tracker.UI.ArmingLive,
    Wotex.Tracker.UI.AssetRemoveLive,
    Wotex.Tracker.UI.AssetLive,
    Wotex.Tracker.UI.AssociationLive,
    Wotex.Tracker.UI.AssociationSelectLive,
    Wotex.Tracker.UI.BrowseLive,
    Wotex.Tracker.UI.DashboardCompareLive,
    Wotex.Tracker.UI.DashboardIndexLive,
    Wotex.Tracker.UI.DashboardLive,
    Wotex.Tracker.UI.ObservationLive,
    Wotex.Tracker.UI.OperationalLive,
    Wotex.Tracker.UI.PrivacyLive,
    Wotex.Tracker.UI.ProtectionLive,
    Wotex.Tracker.UI.RouteLive,
    Wotex.Tracker.UI.RuleCreateLive,
    Wotex.Tracker.UI.RuleLive,
    Wotex.Tracker.UI.SafetyLive,
    Wotex.Tracker.UI.TripLive,
    Wotex.Tracker.UI.TripSummaryLive
  ]

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl true
  def init(_) do
    Process.flag(:trap_exit, true)
    :telemetry.detach(@handler)

    events = [@connection_event | @render_events]

    case :telemetry.attach_many(@handler, events, &__MODULE__.handle_event/4, nil) do
      :ok -> {:ok, nil}
      {:error, reason} -> {:stop, reason}
    end
  end

  @doc false
  def handle_event(
        @connection_event,
        %{duration: duration},
        %{
          endpoint: Endpoint,
          user_socket: Phoenix.LiveView.Socket,
          params: %{"wotex_reconnect" => "1"},
          result: result
        },
        _
      )
      when is_integer(duration) and duration >= 0 and result in [:ok, :error] do
    outcome = if result == :ok, do: :ok, else: :unavailable
    OperationalTelemetry.browser_connection(outcome, duration)
  end

  def handle_event(event, %{duration: duration}, %{socket: %{view: view}} = metadata, _)
      when event in @render_events and is_integer(duration) and duration >= 0 do
    if view in @views and not Map.has_key?(metadata, :component) do
      outcome = if List.last(event) == :stop, do: :ok, else: :unavailable
      OperationalTelemetry.browser_render(outcome, duration)
    end
  end

  def handle_event(_, _, _, _), do: :ok

  @impl true
  def terminate(_, _) do
    :telemetry.detach(@handler)
    :ok
  end
end
