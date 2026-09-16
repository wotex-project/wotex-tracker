defmodule Wotex.Tracker.UI.HistoryExport do
  @moduledoc "Exports one reauthorized public state-history page without its session-bound cursors."

  alias Phoenix.LiveView

  @spec push(LiveView.Socket.t(), String.t(), map()) :: LiveView.Socket.t()
  def push(socket, asset, %{"items" => items, "generation" => generation} = page)
      when is_binary(asset) and is_list(items) and is_binary(generation) do
    document = %{
      "schema" => "wtr.history-page-export.v1",
      "resource" => "state",
      "asset_id" => asset,
      "snapshot_generation" => generation,
      "order" => "commit_generation_ascending",
      "page_count" => length(items),
      "has_more" => is_binary(page["cursor"]),
      "items" => items
    }

    LiveView.push_event(socket, "download-history-page", %{"content" => Jason.encode!(document)})
  end
end
