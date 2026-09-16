defmodule Wotex.Tracker.AnalyticsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Wotex.Tracker.{Analytics, QueryResult, QueryRow, QuerySpec}

  test "numeric buckets preserve gaps and disclose unavailable and rejected quality" do
    rows = [
      row("a-0", "a", 0, 1),
      row("a-500", "a", 500, 3),
      row("a-gap", "a", 1_000, nil, availability: :unavailable),
      row("a-2000", "a", 2_000, 4),
      row("a-suspect", "a", 3_000, 99, quality: :suspect),
      row("b-1000", "b", 1_000, 10)
    ]

    assert {:ok, result} = Analytics.evaluate(rows, spec(), "generation-7")
    assert result.scanned_rows == 6
    assert result.selected_rows == 6
    assert result.qualified_rows == 4
    assert result.excluded_unavailable == 1
    assert result.excluded_quality == 1

    assert [%{"id" => "a", "points" => a}, %{"id" => "b", "points" => b}] = result.series

    assert Enum.map(a, &{&1["start_at"], &1["value"], &1["sample_count"]}) == [
             {0, 2.0, 2},
             {2_000, 4.0, 1}
           ]

    assert Enum.map(b, &{&1["start_at"], &1["value"]}) == [{1_000, 10.0}]
    refute Enum.any?(a, &(&1["start_at"] == 1_000))

    assert {:ok, document} = QueryResult.to_map(result)
    assert QueryResult.from_map(document) == {:ok, result}
  end

  test "count, min, max and last are deterministic with stable timestamp ties" do
    rows = [row("first", "a", 10, 3), row("second", "a", 10, 7), row("third", "a", 20, 5)]

    for {aggregation, expected} <- [count: 3, min: 3, max: 7] do
      query = spec(%{aggregation: aggregation, from_at: 0, to_at: 1_000, bucket_ms: 1_000})
      assert {:ok, result} = Analytics.evaluate(rows, query, "snapshot")
      assert get_in(result.series, [Access.at(0), "points", Access.at(0), "value"]) == expected
    end

    query = spec(%{aggregation: :last, from_at: 0, to_at: 1_000, bucket_ms: 1_000})
    assert {:ok, result} = Analytics.evaluate(rows, query, "snapshot")
    point = get_in(result.series, [Access.at(0), "points", Access.at(0)])
    assert point["value"] == 5
    assert point["last_event_at"] == 20
  end

  test "descending order and input permutations retain the same result identity" do
    rows = [row("one", "a", 0, 1), row("two", "a", 1_000, 2), row("three", "b", 2_000, 3)]
    query = spec(%{aggregation: :last, order: :descending})

    assert {:ok, forward} = Analytics.evaluate(rows, query, "snapshot")
    assert {:ok, reverse} = Analytics.evaluate(Enum.reverse(rows), query, "snapshot")
    assert forward === reverse

    assert [1_000, 0] ==
             forward.series
             |> hd()
             |> Map.fetch!("points")
             |> Enum.map(& &1["start_at"])
  end

  test "query and row codecs reject changed closed content" do
    query = spec()
    value = row("row", "a", 0, 1)
    assert {:ok, query_document} = QuerySpec.to_map(query)
    assert QuerySpec.from_map(query_document) == {:ok, query}
    assert {:ok, row_document} = QueryRow.to_map(value)
    assert QueryRow.from_map(row_document) == {:ok, value}

    for changed <- [
          Map.put(query_document, "identity", "forged"),
          Map.put(query_document, "timezone", "Europe/Stockholm"),
          Map.put(query_document, "extra", true)
        ] do
      assert {:error, _} = QuerySpec.from_map(changed)
    end

    for changed <- [
          Map.put(row_document, "identity", "forged"),
          Map.put(row_document, "availability", "unavailable"),
          Map.put(row_document, "extra", true)
        ] do
      assert {:error, _} = QueryRow.from_map(changed)
    end

    for aggregation <- [:count, :min, :max, :mean, :last] do
      admitted = spec(%{aggregation: aggregation})
      assert {:ok, document} = QuerySpec.to_map(admitted)
      assert QuerySpec.from_map(document) == {:ok, admitted}
    end

    admitted = spec(%{qualities: [:valid, :suspect], order: :descending})
    assert {:ok, document} = QuerySpec.to_map(admitted)
    assert QuerySpec.from_map(document) == {:ok, admitted}

    for changed <- [
          Map.put(document, "aggregation", "median"),
          Map.put(document, "order", "random"),
          Map.put(document, "qualities", ["invented"]),
          Map.put(document, "qualities", "valid"),
          Map.put(document, "schema", "invented")
        ] do
      assert {:error, _} = QuerySpec.from_map(changed)
    end

    for quality <- [:suspect, :invalid] do
      admitted = row("#{quality}", "a", 0, 1.5, quality: quality)
      assert {:ok, document} = QueryRow.to_map(admitted)
      assert QueryRow.from_map(document) == {:ok, admitted}
    end

    for changed <- [
          Map.put(row_document, "availability", "invented"),
          Map.put(row_document, "quality", "invented")
        ] do
      assert {:error, _} = QueryRow.from_map(changed)
    end
  end

  test "queries reject unit conflicts, duplicate rows and over-budget plans" do
    query = spec()
    value = row("row", "a", 0, 1)
    assert {:error, %{code: :conflict}} = Analytics.evaluate([value, value], query, "snapshot")

    assert {:error, %{code: :conflict}} =
             Analytics.evaluate([row("wrong-unit", "a", 0, 1, unit: "mV")], query, "snapshot")

    for change <- [
          %{series: []},
          %{series: :all},
          %{series: [""]},
          %{series: List.duplicate("a", 2)},
          %{qualities: []},
          %{qualities: :all},
          %{from_at: 1_000, to_at: 1_000},
          %{to_at: 2_678_400_001},
          %{timezone: "Europe/Stockholm"},
          %{bucket_ms: 1, max_points: 3},
          %{aggregation: :median},
          %{extra: true}
        ] do
      assert {:error, _} = QuerySpec.new(Map.merge(spec_input(), change)), inspect(change)
    end
  end

  test "unavailable rows require nil while available values remain finite numbers" do
    assert {:ok, _} = QueryRow.new(row_input("missing", "a", 0, nil, :unavailable, :valid, "V"))
    assert {:error, _} = QueryRow.new(row_input("bad", "a", 0, nil, :available, :valid, "V"))
    assert {:error, _} = QueryRow.new(row_input("bad", "a", 0, 1, :unavailable, :valid, "V"))

    assert {:error, _} =
             QueryRow.new(
               Map.put(row_input("bad", "a", 0, 1, :available, :valid, "V"), :extra, true)
             )

    assert {:error, _} = QueryRow.validate(:invalid)
    assert {:error, _} = QuerySpec.validate(:invalid)
    assert {:error, _} = QueryResult.validate(:invalid)
  end

  test "result admission binds bucket geometry, totals, order and count values" do
    rows = [row("one", "a", 0, 1), row("two", "a", 500, 2)]
    assert {:ok, result} = Analytics.evaluate(rows, spec(), "snapshot")
    input = result_input(result)
    [a, b] = result.series
    [point] = a["points"]

    invalid_inputs = [
      %{input | selected_rows: 1},
      %{input | scanned_rows: 100_001},
      %{input | series: :invalid},
      %{input | series: [:invalid, b]},
      %{input | series: [%{"points" => []}, b]},
      %{input | series: [Map.put(a, "id", "b"), b]},
      %{input | series: [Map.put(a, "unit", "mV"), b]},
      %{input | series: [Map.put(a, "points", [point, point]), b]},
      %{input | series: [Map.put(a, "points", [Map.put(point, "start_at", 1)]), b]},
      %{input | series: [Map.put(a, "points", [Map.put(point, "value", nil)]), b]},
      %{input | series: [Map.put(a, "points", [Map.put(point, "sample_count", 1)]), b]}
    ]

    for invalid <- invalid_inputs do
      assert {:error, _} = QueryResult.new(invalid)
    end

    assert {:error, _} = QueryResult.new(input, max_material_bytes: 1)

    count_query = spec(%{aggregation: :count})
    assert {:ok, count_result} = Analytics.evaluate(rows, count_query, "snapshot")
    [count_a, count_b] = count_result.series
    [count_point] = count_a["points"]

    changed_count =
      count_result
      |> result_input()
      |> Map.put(:series, [
        Map.put(count_a, "points", [Map.put(count_point, "value", 7)]),
        count_b
      ])

    assert {:error, _} = QueryResult.new(changed_count)

    assert {:ok, document} = QueryResult.to_map(result)
    assert {:error, _} = document |> Map.put("schema", "invented") |> QueryResult.from_map()
    assert {:error, _} = document |> Map.put("identity", "forged") |> QueryResult.from_map()
  end

  test "analytics rejects malformed rows and enforces its scan ceiling before validation" do
    assert {:error, _} = Analytics.evaluate([:invalid], spec(), "snapshot")

    assert {:error, %{code: :limit_exceeded}} =
             Analytics.evaluate(List.duplicate(:invalid, 100_001), spec(), "snapshot")
  end

  property "row input order does not change deterministic aggregation" do
    check all(values <- uniq_list_of(integer(-1_000..1_000), min_length: 1, max_length: 20)) do
      rows =
        values
        |> Enum.with_index()
        |> Enum.map(fn {value, index} -> row("row-#{index}", "a", index * 10, value) end)

      query = spec(%{from_at: 0, to_at: 1_000, bucket_ms: 1_000})
      {:ok, forward} = Analytics.evaluate(rows, query, "snapshot")
      {:ok, reverse} = Analytics.evaluate(Enum.reverse(rows), query, "snapshot")
      assert forward === reverse
    end
  end

  defp spec(changes \\ %{}) do
    {:ok, value} = QuerySpec.new(Map.merge(spec_input(), changes))
    value
  end

  defp spec_input,
    do: %{
      id: "voltage-history",
      revision: "query-v1",
      dataset: :measurements,
      measurement: "batteryVoltage",
      unit: "V",
      series: ["a", "b"],
      qualities: [:valid],
      from_at: 0,
      to_at: 4_000,
      timezone: "Etc/UTC",
      bucket_ms: 1_000,
      aggregation: :mean,
      order: :ascending,
      max_points: 4
    }

  defp row(id, series, event_at, value, options \\ []) do
    availability = Keyword.get(options, :availability, :available)
    quality = Keyword.get(options, :quality, :valid)
    unit = Keyword.get(options, :unit, "V")

    {:ok, value} =
      QueryRow.new(row_input(id, series, event_at, value, availability, quality, unit))

    value
  end

  defp row_input(id, series, event_at, value, availability, quality, unit),
    do: %{
      measurement: "batteryVoltage",
      series: series,
      event_at: event_at,
      value: value,
      unit: unit,
      availability: availability,
      quality: quality,
      evidence_identity: id
    }

  defp result_input(result) do
    Map.take(
      result,
      ~w(spec snapshot series scanned_rows selected_rows qualified_rows excluded_unavailable excluded_quality)a
    )
  end
end
