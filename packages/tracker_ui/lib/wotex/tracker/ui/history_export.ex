defmodule Wotex.Tracker.UI.HistoryExport do
  @moduledoc "Exports one reauthorized public state-history page without its session-bound cursors."

  alias Phoenix.LiveView

  @page_size 100
  @max_pages 10
  @max_bytes 1_000_000

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

  @doc "Collects one complete retained history within fixed page, row and byte budgets."
  @spec collect(String.t(), (map() -> {:ok, map()} | {:error, map()})) ::
          {:ok, map()} | {:error, map()}
  def collect(asset, fetch) when is_binary(asset) and is_function(fetch, 1) do
    collect_pages(asset, fetch, %{"limit" => @page_size}, nil, [], 0, 0, MapSet.new())
  rescue
    _ -> {:error, %{"code" => "storage_unavailable"}}
  end

  @doc "Emits a completed export that contains no service continuation cursor."
  @spec push_complete(LiveView.Socket.t(), map()) :: LiveView.Socket.t()
  def push_complete(socket, document),
    do: LiveView.push_event(socket, "download-history", %{"content" => Jason.encode!(document)})

  defp collect_pages(asset, fetch, params, generation, rows, pages, bytes, seen) do
    case safe_fetch(fetch, params) do
      {:ok, %{"items" => items, "generation" => current, "cursor" => cursor} = page}
      when is_list(items) and length(items) <= @page_size and is_binary(current) and
             (is_nil(cursor) or is_binary(cursor)) ->
        accept_page(asset, fetch, page, generation, rows, pages, bytes, seen)

      {:error, %{"code" => _} = error} ->
        {:error, error}

      _ ->
        {:error, %{"code" => "storage_unavailable"}}
    end
  end

  defp accept_page(asset, fetch, page, generation, rows, pages, bytes, seen) do
    current = page["generation"]
    items = page["items"]
    cursor = page["cursor"]
    next_pages = pages + 1
    next_bytes = bytes + byte_size(Jason.encode!(items))
    next_rows = Enum.reverse(items, rows)

    cond do
      generation && generation != current ->
        {:error, %{"code" => "conflict"}}

      next_bytes > @max_bytes ->
        {:error, %{"code" => "export_limit"}}

      is_nil(cursor) ->
        complete(asset, current, next_rows, next_pages)

      next_pages == @max_pages ->
        {:error, %{"code" => "export_limit"}}

      MapSet.member?(seen, cursor) ->
        {:error, %{"code" => "invalid_cursor"}}

      true ->
        collect_pages(
          asset,
          fetch,
          %{"limit" => @page_size, "cursor" => cursor},
          current,
          next_rows,
          next_pages,
          next_bytes,
          MapSet.put(seen, cursor)
        )
    end
  end

  defp complete(asset, generation, rows, pages) do
    items = Enum.reverse(rows)

    document = %{
      "schema" => "wtr.history-export.v1",
      "resource" => "state",
      "asset_id" => asset,
      "snapshot_generation" => generation,
      "order" => "commit_generation_ascending",
      "complete" => true,
      "page_count" => pages,
      "item_count" => length(items),
      "items" => items
    }

    if byte_size(Jason.encode!(document)) <= @max_bytes,
      do: {:ok, document},
      else: {:error, %{"code" => "export_limit"}}
  end

  defp safe_fetch(fetch, params) do
    fetch.(params)
  rescue
    _ -> {:error, %{"code" => "storage_unavailable"}}
  catch
    :exit, _ -> {:error, %{"code" => "storage_unavailable"}}
  end
end
