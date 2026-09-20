defmodule Wotex.Tracker.Mobile.Sharing do
  @moduledoc """
  Closed OS-share boundary for already-authorized shared-UI JSON exports.

  Browser downloads stay in the shared UI. On the native host, only the fixed
  export filenames and their existing JSON schemas can reach Mob's text share
  sheet. This module performs no fetch and accepts no URL, path or native method.
  """

  @maximum_bytes 1_048_576
  @schemas %{
    "wotex-query-result.json" => "wtr.query-result.v1",
    "wotex-history-page.json" => "wtr.history-page-export.v1",
    "wotex-retained-history.json" => "wtr.history-export.v1",
    "wotex-route-page.json" => "wtr.route-page-export.v1",
    "wotex-trip-events.json" => "wtr.trip-event-page-export.v1",
    "wotex-trip-summary.json" => "wtr.trip-summary-export.v1"
  }
  @raw ~w(wotex-native-observation.json wotex-raw-evidence.json)

  @doc "Shares one exact bounded JSON export through the native system sheet."
  @spec share(Mob.Socket.t(), term(), module()) :: Mob.Socket.t()
  def share(socket, payload, native \\ Mob.Share)

  def share(socket, payload, native) when is_atom(native) do
    with {:ok, contract, content} <- admit(payload),
         {:ok, document} <- Jason.decode(content),
         true <- document?(document, contract),
         %Mob.Socket{} = updated <- native.text(socket, content) do
      updated
    else
      _ -> socket
    end
  rescue
    _ -> socket
  catch
    _, _ -> socket
  end

  def share(socket, _, _), do: socket

  defp admit(
         %{
           "schema" => "wtr.mobile-share.v1",
           "filename" => filename,
           "media_type" => "application/json",
           "content" => content
         } = payload
       )
       when map_size(payload) == 4 and is_binary(filename) and is_binary(content) and
              byte_size(content) in 1..@maximum_bytes do
    with true <- String.valid?(content),
         {:ok, contract} <- contract(filename) do
      {:ok, contract, content}
    else
      _ -> {:error, :invalid_share}
    end
  end

  defp admit(_), do: {:error, :invalid_share}

  defp contract(filename) do
    case @schemas do
      %{^filename => schema} -> {:ok, {:schema, schema}}
      _ -> if filename in @raw, do: {:ok, :raw}, else: {:error, :invalid_share}
    end
  end

  defp document?(%{"schema" => schema}, {:schema, schema}), do: true
  defp document?(document, :raw), do: is_map(document) or is_list(document)
  defp document?(_, _), do: false
end
