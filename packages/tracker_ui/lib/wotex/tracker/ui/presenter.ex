defmodule Wotex.Tracker.UI.Presenter do
  @moduledoc """
  Formats public service values for the shared browser screens.

  These helpers label known measurement kinds and units, construct encoded
  local paths, and display scalar values, timestamps, and bounded error text.
  They do not convert units, turn missing values into zero, or infer freshness
  from a recorded timestamp. Canonical values remain in the service result.
  """

  @errors %{
    "forbidden" => "Your credential does not permit this operation.",
    "unauthorized" => "Your session has expired or access was revoked. Sign in again.",
    "conflict" =>
      "The service changed since this page loaded. Refresh and review before trying again.",
    "idempotency_conflict" =>
      "This operation was already submitted with different details. Inspect its existing outcome.",
    "unresolved" => "This observation has no supported exact profile and cannot be enrolled.",
    "invalid_request" => "Check the required fields and confirmation.",
    "capacity_exceeded" =>
      "This asset already has eight rule definitions. Delete one before adding another.",
    "not_found" => "The requested record is not available.",
    "cursor_expired" => "This page has expired. Refresh to start a new snapshot.",
    "operation_expired" =>
      "This operation's receipt has expired. Review existing assets before starting another enrollment.",
    "operation_mismatch" =>
      "This operation reference belongs to a different workflow. No new operation was submitted.",
    "overloaded" => "The query service is busy. Wait before running another query.",
    "unsupported" => "This host does not provide this view.",
    "invalid_cursor" => "This operational page can no longer be resumed. Refresh to start again.",
    "invalid_query" => "Check the selected operational filter and refresh.",
    "export_limit" =>
      "This retained history exceeds the 1,000-row or 1 MB download limit. Export individual pages instead.",
    "unavailable" => "Operational history is temporarily unavailable. Refresh to retry.",
    "prompt_unavailable" =>
      "The question provider is unavailable. You can still run a structured query.",
    "prompt_invalid" =>
      "The question could not be turned into a valid query. Review the structured form."
  }
  @unknown_error "The service could not complete this request. Keep the operation reference and check its outcome before retrying."
  @labels %{
    "temperature" => "Temperature",
    "humidity" => "Humidity",
    "pressure" => "Pressure",
    "accelerationX" => "Acceleration X",
    "accelerationY" => "Acceleration Y",
    "accelerationZ" => "Acceleration Z",
    "batteryVoltage" => "Battery voltage",
    "txPower" => "Transmit power",
    "movementCounter" => "Movement counter",
    "measurementSequence" => "Measurement sequence"
  }

  @doc "Provides a readable label without changing the canonical measurement kind."
  @spec label(String.t()) :: String.t()
  def label(kind), do: Map.get(@labels, kind, kind)

  @doc "Displays known unit symbols without converting the measurement value."
  @spec unit(String.t()) :: String.t()
  def unit(unit), do: Map.get(%{"Cel" => "°C", "1" => ""}, unit, unit)

  @doc "Builds a local path using one encoded identifier segment."
  @spec path(:asset | :observation, String.t()) :: String.t()
  def path(kind, id) when kind in [:asset, :observation] and is_binary(id) do
    prefix = if kind == :asset, do: "/assets/", else: "/observations/"
    prefix <> URI.encode(id, &URI.char_unreserved?/1)
  end

  @doc "Builds the local path for reviewing one observation against an existing asset."
  @spec association_path(String.t(), String.t()) :: String.t()
  def association_path(thing, observation) when is_binary(thing) and is_binary(observation),
    do:
      path(:asset, thing) <> "/observations/" <> URI.encode(observation, &URI.char_unreserved?/1)

  @doc "Builds the local path for one saved dashboard definition."
  @spec dashboard_path(String.t()) :: String.t()
  def dashboard_path(id) when is_binary(id),
    do: "/dashboards/" <> URI.encode(id, &URI.char_unreserved?/1)

  @doc "Builds the local path for one persisted rule status."
  @spec rule_path(String.t()) :: String.t()
  def rule_path(id) when is_binary(id),
    do: "/protection/" <> URI.encode(id, &URI.char_unreserved?/1)

  @doc "Names a closed rule kind without implying the rule is armed or configurable here."
  @spec rule_kind(String.t()) :: String.t()
  def rule_kind(kind),
    do:
      Map.get(
        %{
          "battery" => "Low battery",
          "geofence" => "Geofence",
          "heartbeat" => "Reporting heartbeat",
          "motion" => "Motion and trips",
          "transport_degradation" => "Transport health"
        },
        kind,
        kind
      )

  @doc "Summarizes a managed rule definition's stored parameters without rounding it."
  @spec rule_parameters(String.t(), term()) :: String.t()
  def rule_parameters("heartbeat", %{"maximum_silence_ms" => silence}) when is_integer(silence),
    do: "Maximum silence " <> duration(%{"type" => "integer", "value" => silence})

  def rule_parameters(
        "battery",
        %{"low_threshold" => low, "clear_threshold" => clear, "unit" => unit} = parameters
      )
      when is_number(low) and is_number(clear) and is_binary(unit) do
    "Low at or below #{low} #{unit(unit)} · clears at or above #{clear} #{unit(unit)} · " <>
      "maximum reading age " <>
      duration(%{"type" => "integer", "value" => parameters["maximum_age_ms"]})
  end

  def rule_parameters(
        "motion",
        %{
          "moving_speed_m_s" => moving_speed,
          "stationary_speed_m_s" => stationary_speed,
          "minimum_movement_ms" => movement,
          "minimum_stop_ms" => stop
        }
      ) do
    "Moving ≥ #{moving_speed} m/s · stationary ≤ #{stationary_speed} m/s · " <>
      "dwell #{duration(%{"type" => "integer", "value" => movement})} / " <>
      duration(%{"type" => "integer", "value" => stop})
  end

  def rule_parameters("geofence", %{"shape" => shape, "max_transition_gap_ms" => gap}) do
    fence_shape(shape) <>
      " · transition gap " <> duration(%{"type" => "integer", "value" => gap})
  end

  def rule_parameters(_, _), do: "Parameters unavailable"

  defp fence_shape(%{
         "kind" => "circle",
         "latitude" => latitude,
         "longitude" => longitude,
         "radius_m" => radius
       }),
       do: "Circle at #{latitude}, #{longitude} · radius #{radius} m"

  defp fence_shape(%{"kind" => "polygon", "vertices" => vertices}) when is_list(vertices),
    do: "Polygon · #{length(vertices)} vertices"

  defp fence_shape(_), do: "Fence geometry unavailable"

  @doc "Reports whether a rule status describes a condition an operator should review."
  @spec rule_attention?(term()) :: boolean()
  def rule_attention?(status), do: status in ~w(overdue low degraded outside)

  @doc "Labels a closed rule status, keeping unknown distinct from a negative result."
  @spec rule_status(String.t()) :: String.t()
  def rule_status(status),
    do:
      Map.get(
        %{
          "current" => "Reporting on time",
          "overdue" => "Overdue",
          "normal" => "Normal",
          "low" => "Low",
          "healthy" => "Healthy",
          "degraded" => "Degraded",
          "stationary" => "Stationary",
          "moving" => "Moving",
          "inside" => "Inside",
          "outside" => "Outside",
          "uncertain" => "Uncertain",
          "unknown" => "Unknown"
        },
        status,
        status
      )

  @doc "Builds the local path for one recorded alert."
  @spec alert_path(String.t()) :: String.t()
  def alert_path(id) when is_binary(id),
    do: "/protection/alerts/" <> URI.encode(id, &URI.char_unreserved?/1)

  @doc "Names a recorded rule event kind, falling back to its canonical name."
  @spec alert_kind(String.t()) :: String.t()
  def alert_kind(kind),
    do:
      Map.get(
        %{
          "heartbeat.overdue" => "Reporting overdue",
          "heartbeat.recovered" => "Reporting recovered",
          "heartbeat.recomputed" => "Heartbeat rule recomputed",
          "battery.low" => "Battery low",
          "battery.recovered" => "Battery recovered",
          "battery.recomputed" => "Battery rule recomputed",
          "transport.degraded" => "Transport degraded",
          "transport.recovered" => "Transport recovered",
          "transport.recomputed" => "Transport rule recomputed",
          "trip.started" => "Trip started",
          "trip.stopped" => "Trip stopped",
          "trip.interrupted" => "Trip interrupted",
          "geofence.entered" => "Geofence entered",
          "geofence.exited" => "Geofence exited"
        },
        kind,
        kind
      )

  @doc "Describes whether an alert needs review, is acknowledged or is only a replay record."
  @spec alert_state(map()) :: String.t()
  def alert_state(%{"acknowledgement" => %{"at" => at}}),
    do: "Acknowledged " <> timestamp(%{"value" => at})

  def alert_state(%{"mode" => "live"}), do: "Needs review"
  def alert_state(_), do: "Replay record; no review needed"

  @doc "Formats a tagged millisecond duration without rounding it into a coarser unit."
  @spec duration(term()) :: String.t()
  def duration(%{"type" => "integer", "value" => value}) when is_integer(value),
    do: "#{value} ms"

  def duration(_), do: "Unknown"

  @doc "Formats a tagged public scalar without converting unavailable values to zero."
  @spec scalar(term()) :: String.t()
  def scalar(%{"value" => nil}), do: "Unavailable"

  def scalar(%{"value" => value}) when is_number(value) or is_boolean(value) or is_binary(value),
    do: to_string(value)

  def scalar(_), do: "Unknown"

  @doc "Formats an admitted millisecond timestamp in UTC, without inferring freshness."
  @spec timestamp(term()) :: String.t()
  def timestamp(%{"value" => value}) when is_integer(value) do
    case DateTime.from_unix(value, :millisecond) do
      {:ok, time} -> Calendar.strftime(time, "%Y-%m-%d %H:%M:%S UTC")
      _ -> "Unknown time"
    end
  end

  def timestamp(_), do: "Unknown time"

  @doc "Names a declared position source without changing its canonical value."
  @spec position_source(term()) :: String.t()
  def position_source(source),
    do:
      Map.get(
        %{
          "gnss" => "GNSS",
          "cellular" => "Cellular",
          "wifi" => "Wi-Fi",
          "ble" => "BLE proximity",
          "lorawan" => "LoRaWAN",
          "operator" => "Operator supplied"
        },
        source,
        "Unknown source"
      )

  @doc "Formats one closed public position without inferring freshness or canonical selection."
  @spec position_summary(term()) :: String.t()
  def position_summary(%{"availability" => "unavailable", "source" => source}),
    do: position_source(source) <> " position unavailable"

  def position_summary(
        %{
          "availability" => "available",
          "source" => source,
          "latitude" => latitude,
          "longitude" => longitude,
          "quality" => quality
        } = position
      ) do
    position_source(source) <>
      ": " <>
      scalar(latitude) <>
      ", " <>
      scalar(longitude) <>
      " · " <> position_accuracy(position) <> " · quality " <> quality
  end

  def position_summary(_), do: "Position unavailable"

  @doc "Formats declared horizontal position accuracy without converting uncertainty kind."
  @spec position_accuracy(term()) :: String.t()
  def position_accuracy(%{
        "accuracy_kind" => kind,
        "horizontal_accuracy_m" => %{"value" => value}
      })
      when kind in ~w(estimate bound) and is_number(value),
      do: "#{kind} accuracy #{value} m"

  def position_accuracy(_), do: "accuracy unknown"

  @doc "Provides a bounded user-facing explanation of a service error."
  @spec error(term()) :: String.t()
  def error(%{"code" => code}), do: Map.get(@errors, code, @unknown_error)

  def error(_), do: "The service is unavailable."
end
