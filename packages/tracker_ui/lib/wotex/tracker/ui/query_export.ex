defmodule Wotex.Tracker.UI.QueryExport do
  @moduledoc "Downloads the exact authorized query result already held by a LiveView."

  alias Phoenix.LiveView

  @spec push(LiveView.Socket.t(), map()) :: LiveView.Socket.t()
  def push(socket, result) when is_map(result) do
    LiveView.push_event(socket, "download-query-result", %{"content" => Jason.encode!(result)})
  end
end
