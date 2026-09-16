defmodule Wotex.Tracker.UI.HistoryExportTest do
  @moduledoc false
  use ExUnit.Case, async: true
  alias Wotex.Tracker.UI.HistoryExport

  test "collects a complete cursor-pinned history without exporting cursors" do
    fetch = fn
      %{"limit" => 100} = params when map_size(params) == 1 ->
        {:ok, page([%{"generation" => "3"}], "7", "next")}

      %{"limit" => 100, "cursor" => "next"} ->
        {:ok, page([%{"generation" => "5"}], "7", nil)}
    end

    assert {:ok, document} = HistoryExport.collect("asset", fetch)
    assert document["schema"] == "wtr.history-export.v1"
    assert document["snapshot_generation"] == "7"
    assert document["item_count"] == 2
    assert document["page_count"] == 2
    assert document["complete"] == true
    assert Enum.map(document["items"], & &1["generation"]) == ~w(3 5)
    refute Map.has_key?(document, "cursor")
  end

  test "changed generation, repeated cursor and denied page never return a partial export" do
    changed = fn
      %{"cursor" => "next"} -> {:ok, page([], "8", nil)}
      _ -> {:ok, page([%{"generation" => "3"}], "7", "next")}
    end

    assert {:error, %{"code" => "conflict"}} = HistoryExport.collect("asset", changed)

    repeated = fn _ -> {:ok, page([%{"generation" => "3"}], "7", "next")} end
    assert {:error, %{"code" => "invalid_cursor"}} = HistoryExport.collect("asset", repeated)

    denied = fn
      %{"cursor" => "next"} -> {:error, %{"code" => "forbidden"}}
      _ -> {:ok, page([%{"generation" => "3"}], "7", "next")}
    end

    assert {:error, %{"code" => "forbidden"}} = HistoryExport.collect("asset", denied)
  end

  test "rejects oversized and malformed histories before download" do
    oversized = fn _ ->
      {:ok, page([%{"value" => String.duplicate("x", 1_000_000)}], "7", nil)}
    end

    assert {:error, %{"code" => "export_limit"}} = HistoryExport.collect("asset", oversized)

    malformed = fn _ -> {:ok, %{"items" => [], "generation" => "7", "cursor" => 12}} end

    assert {:error, %{"code" => "storage_unavailable"}} =
             HistoryExport.collect("asset", malformed)

    raised = fn _ -> raise "failed" end
    assert {:error, %{"code" => "storage_unavailable"}} = HistoryExport.collect("asset", raised)
  end

  defp page(items, generation, cursor),
    do: %{"items" => items, "generation" => generation, "cursor" => cursor}
end
