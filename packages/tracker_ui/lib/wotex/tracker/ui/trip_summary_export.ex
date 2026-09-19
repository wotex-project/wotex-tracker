defmodule Wotex.Tracker.UI.TripSummaryExport do
  @moduledoc """
  Reauthorizes and exports one displayed completed-trip distance summary.

  Verification reruns the exact Thing/trip request and requires the immutable
  public identity to match. The bounded export contains only the already public
  summary and carries no bearer token, service cursor or private input identity.
  """

  alias Phoenix.LiveView
  alias Wotex.Tracker.UI.Auth

  @max_bytes 1_000_000

  @doc "Replays the exact request under current authority and compares content identity."
  @spec verify(LiveView.Socket.t(), String.t(), String.t(), map()) :: :ok | {:error, map()}
  def verify(socket, thing, trip, %{"identity" => identity})
      when is_binary(thing) and is_binary(trip) and is_binary(identity) do
    case Auth.request(socket, :trip_summary, %{"thing" => thing, "trip" => trip}) do
      {:ok, %{"identity" => ^identity}} -> :ok
      {:ok, _} -> {:error, %{"code" => "conflict"}}
      {:error, error} -> {:error, error}
    end
  end

  @doc "Emits one bounded public summary export."
  @spec push(LiveView.Socket.t(), map(), map()) ::
          {:ok, LiveView.Socket.t()} | {:error, map()}
  def push(socket, summary, presentation) when is_map(summary) and is_map(presentation) do
    document = %{
      "schema" => "wtr.trip-summary-export.v1",
      "thing_id" => summary["thing_id"],
      "trip_id" => summary["trip_id"],
      "snapshot_generation" => summary["snapshot_generation"],
      "summary_identity" => summary["identity"],
      "presentation" => presentation,
      "summary" => summary
    }

    encoded = Jason.encode!(document)

    if byte_size(encoded) <= @max_bytes,
      do: {:ok, LiveView.push_event(socket, "download-trip-summary", %{"content" => encoded})},
      else: {:error, %{"code" => "export_limit"}}
  end
end
