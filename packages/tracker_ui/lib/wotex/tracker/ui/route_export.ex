defmodule Wotex.Tracker.UI.RouteExport do
  @moduledoc """
  Reauthorizes and exports one displayed retained-route page.

  Verification reruns the exact cursor-bound request and requires the same page
  identity. The exported document keeps the public replay and snapshot metadata
  but removes the service continuation cursor; possession of a downloaded file
  cannot resume or authorize a traversal.
  """

  alias Phoenix.LiveView
  alias Wotex.Tracker.UI.Auth

  @max_bytes 1_000_000

  @doc "Replays the exact request under current authority and compares content identity."
  @spec verify(LiveView.Socket.t(), map(), map()) :: :ok | {:error, map()}
  def verify(socket, %{"identity" => identity}, request)
      when is_binary(identity) and is_map(request) do
    case Auth.request(socket, :route_history, %{"request" => request}) do
      {:ok, %{"identity" => ^identity}} -> :ok
      {:ok, _} -> {:error, %{"code" => "conflict"}}
      {:error, error} -> {:error, error}
    end
  end

  @doc "Emits a bounded cursor-free public route-page export."
  @spec push(LiveView.Socket.t(), map()) ::
          {:ok, LiveView.Socket.t()} | {:error, map()}
  def push(socket, page) when is_map(page) do
    document = %{
      "schema" => "wtr.route-page-export.v1",
      "thing_id" => page["thing_id"],
      "snapshot_generation" => page["generation"],
      "history" => page["history"],
      "window" => page["window"],
      "continuity" => page["continuity"],
      "route" => page["route"],
      "page_identity" => page["identity"],
      "has_more" => is_binary(page["cursor"])
    }

    encoded = Jason.encode!(document)

    if byte_size(encoded) <= @max_bytes,
      do: {:ok, LiveView.push_event(socket, "download-route-page", %{"content" => encoded})},
      else: {:error, %{"code" => "export_limit"}}
  end
end
