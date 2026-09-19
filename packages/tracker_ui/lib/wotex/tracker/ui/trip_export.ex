defmodule Wotex.Tracker.UI.TripExport do
  @moduledoc """
  Reauthorizes and exports one displayed trip-event page.

  Verification reruns the exact cursor-bound request and requires its public
  records, snapshot and continuation state to match. The exported document omits
  service cursors, so a file cannot authorize or continue traversal.
  """

  alias Phoenix.LiveView
  alias Wotex.Tracker.UI.Auth

  @max_bytes 1_000_000

  @doc "Replays the exact request under current authority and compares the public page."
  @spec verify(LiveView.Socket.t(), String.t(), map(), map()) :: :ok | {:error, map()}
  def verify(socket, thing, shown, params)
      when is_binary(thing) and is_map(shown) and is_map(params) do
    case Auth.request(socket, :thing_trips, %{"thing" => thing, "params" => params}) do
      {:ok, current} ->
        if stable(current) == stable(shown),
          do: :ok,
          else: {:error, %{"code" => "conflict"}}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc "Emits a bounded cursor-free public trip-event page export."
  @spec push(LiveView.Socket.t(), String.t(), map(), map(), map()) ::
          {:ok, LiveView.Socket.t()} | {:error, map()}
  def push(socket, thing, page, window, presentation)
      when is_binary(thing) and is_map(page) and is_map(window) and is_map(presentation) do
    document = %{
      "schema" => "wtr.trip-event-page-export.v1",
      "thing_id" => thing,
      "snapshot_generation" => page["generation"],
      "order" => "newest_first",
      "window" => window,
      "presentation" => presentation,
      "page_count" => length(page["items"]),
      "has_more" => is_binary(page["cursor"]),
      "items" => page["items"]
    }

    encoded = Jason.encode!(document)

    if byte_size(encoded) <= @max_bytes,
      do: {:ok, LiveView.push_event(socket, "download-trip-page", %{"content" => encoded})},
      else: {:error, %{"code" => "export_limit"}}
  end

  defp stable(%{"generation" => generation, "items" => items, "cursor" => cursor})
       when is_binary(generation) and is_list(items),
       do: {generation, items, is_binary(cursor)}

  defp stable(_), do: :invalid
end
