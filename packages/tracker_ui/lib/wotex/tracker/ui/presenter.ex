defmodule Wotex.Tracker.UI.Presenter do
  @moduledoc "Pure display helpers preserving missing values, measurement quality and recorded time."

  @errors %{
    "forbidden" => "Your credential does not permit this operation.",
    "unauthorized" => "Your session has expired or access was revoked. Sign in again.",
    "conflict" =>
      "The service changed since this page loaded. Refresh and review before trying again.",
    "idempotency_conflict" =>
      "This operation was already submitted with different details. Inspect its existing outcome.",
    "unresolved" => "This observation has no supported exact profile and cannot be enrolled.",
    "invalid_request" => "Check the required fields and confirmation.",
    "not_found" => "The requested record is not available.",
    "cursor_expired" => "This page has expired. Refresh to start a new snapshot.",
    "operation_expired" =>
      "This operation's receipt has expired. Review existing assets before starting another enrollment.",
    "operation_mismatch" =>
      "This operation reference belongs to a different workflow. No new operation was submitted.",
    "overloaded" => "The query service is busy. Wait before running another query.",
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

  @doc "Provides a bounded user-facing explanation of a service error."
  @spec error(term()) :: String.t()
  def error(%{"code" => code}), do: Map.get(@errors, code, @unknown_error)

  def error(_), do: "The service is unavailable."
end
