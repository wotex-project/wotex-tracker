defmodule Wotex.Tracker.Host.Browser.RenderTelemetry do
  @moduledoc """
  Records bounded host operational samples for shared LiveView renders.

  The process attaches to the listed Phoenix render telemetry events and
  records duration and outcome through `Wotex.Tracker.Service.OperationalTelemetry`.
  It accepts only known Tracker views, ignores component renders, and detaches
  its handler on termination. Samples contain no rendered page or credential.
  """

  use GenServer

  alias Wotex.Tracker.Service.OperationalTelemetry

  @handler {__MODULE__, :browser}
  @events [
    [:phoenix, :live_view, :render, :stop],
    [:phoenix, :live_view, :render, :exception]
  ]
  @views [
    Wotex.Tracker.UI.AnalyticsLive,
    Wotex.Tracker.UI.AssetLive,
    Wotex.Tracker.UI.AssociationLive,
    Wotex.Tracker.UI.AssociationSelectLive,
    Wotex.Tracker.UI.BrowseLive,
    Wotex.Tracker.UI.DashboardCompareLive,
    Wotex.Tracker.UI.DashboardIndexLive,
    Wotex.Tracker.UI.DashboardLive,
    Wotex.Tracker.UI.ObservationLive,
    Wotex.Tracker.UI.OperationalLive,
    Wotex.Tracker.UI.AccessLive
  ]

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl true
  def init(_) do
    Process.flag(:trap_exit, true)
    :telemetry.detach(@handler)

    case :telemetry.attach_many(@handler, @events, &__MODULE__.handle_event/4, nil) do
      :ok -> {:ok, nil}
      {:error, reason} -> {:stop, reason}
    end
  end

  @doc false
  def handle_event(event, %{duration: duration}, %{socket: %{view: view}} = metadata, _)
      when event in @events and is_integer(duration) and duration >= 0 do
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
