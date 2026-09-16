defmodule Wotex.Tracker.UI.RawExport do
  @moduledoc "Emits grant-gated native observation and evidence JSON as downloads."
  alias Phoenix.LiveView

  @max_bytes 1_048_576

  @doc "Pushes one bounded JSON document without placing it in LiveView assigns."
  @spec push(LiveView.Socket.t(), :observation | :evidence, binary()) ::
          {:ok, LiveView.Socket.t()} | {:error, map()}
  def push(socket, kind, content)
      when kind in [:observation, :evidence] and is_binary(content) and
             byte_size(content) <= @max_bytes do
    case Jason.decode(content) do
      {:ok, document} when is_map(document) or is_list(document) ->
        event =
          if kind == :observation,
            do: "download-raw-observation",
            else: "download-raw-evidence"

        {:ok, LiveView.push_event(socket, event, %{"content" => content})}

      _ ->
        {:error, %{"code" => "storage_unavailable"}}
    end
  end

  def push(_, _, _), do: {:error, %{"code" => "storage_unavailable"}}
end
