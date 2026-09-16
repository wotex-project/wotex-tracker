defmodule Wotex.Tracker.UI.QueryExport do
  @moduledoc "Rechecks current read authority and downloads an unchanged displayed query result."

  alias Phoenix.LiveView
  alias Wotex.Tracker.UI.Auth

  @spec verify(LiveView.Socket.t(), map()) :: :ok | {:error, map()}
  def verify(socket, %{"spec" => spec, "identity" => identity})
      when is_map(spec) and is_binary(identity) do
    case Auth.request(socket, :analytics, %{"query" => spec}) do
      {:ok, %{"identity" => ^identity}} -> :ok
      {:ok, _} -> {:error, %{"code" => "conflict"}}
      {:error, error} -> {:error, error}
    end
  end

  @spec push(LiveView.Socket.t(), map()) :: LiveView.Socket.t()
  def push(socket, result) when is_map(result) do
    LiveView.push_event(socket, "download-query-result", %{"content" => Jason.encode!(result)})
  end
end
