defmodule Wotex.Tracker.Analytics do
  @moduledoc """
  Deterministic bounded aggregation over explicit qualified measurement rows.

  The caller owns authorization and supplies a committed snapshot identity.
  Empty buckets are absent, preserving gaps instead of inventing zero values or
  drawing continuity through unobserved time.
  """

  alias Wotex.Tracker.{Admission, Error, QueryResult, QueryRow, QuerySpec}

  @maximum_rows 100_000

  @doc "Evaluates a query against at most 100,000 explicit rows at one snapshot."
  @spec evaluate(term(), term(), term(), term()) ::
          {:ok, QueryResult.t()} | {:error, Error.t()}
  def evaluate(rows, spec, snapshot, options \\ []) do
    with {:ok, spec} <- QuerySpec.validate(spec, options),
         true <- is_list(rows) and length(rows) <= @maximum_rows,
         {:ok, rows} <- validate_rows(rows, options),
         :ok <- unique(rows),
         :ok <- compatible_units(rows, spec),
         {selected, excluded_unavailable, excluded_quality, qualified} <- select(rows, spec),
         series <- aggregate(qualified, spec),
         {:ok, result} <-
           QueryResult.new(
             %{
               spec: spec,
               snapshot: snapshot,
               series: series,
               scanned_rows: length(rows),
               selected_rows: length(selected),
               qualified_rows: length(qualified),
               excluded_unavailable: excluded_unavailable,
               excluded_quality: excluded_quality
             },
             options
           ) do
      {:ok, result}
    else
      false -> Admission.fail(:limit_exceeded)
      error -> error
    end
  end

  defp validate_rows(rows, options) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      case QueryRow.validate(row, options) do
        {:ok, admitted} -> {:cont, {:ok, [admitted | acc]}}
        error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, admitted} -> {:ok, Enum.reverse(admitted)}
      error -> error
    end)
  end

  defp unique(rows) do
    if rows |> Enum.map(& &1.identity) |> Enum.uniq() |> length() == length(rows),
      do: :ok,
      else: Admission.fail(:conflict)
  end

  defp compatible_units(rows, spec) do
    incompatible =
      Enum.any?(rows, fn row ->
        selected?(row, spec) and row.unit != spec.unit
      end)

    if incompatible, do: Admission.fail(:conflict), else: :ok
  end

  defp select(rows, spec) do
    selected = Enum.filter(rows, &selected?(&1, spec))

    {unavailable, present} = Enum.split_with(selected, &(&1.availability == :unavailable))

    {excluded_quality, qualified} =
      Enum.split_with(present, &(&1.quality not in spec.qualities))

    {selected, length(unavailable), length(excluded_quality), qualified}
  end

  defp selected?(row, spec),
    do:
      row.measurement == spec.measurement and row.series in spec.series and
        row.event_at >= spec.from_at and row.event_at < spec.to_at

  defp aggregate(rows, spec) do
    grouped = Enum.group_by(rows, &{&1.series, bucket_start(&1, spec)})

    Enum.map(spec.series, fn id ->
      points =
        grouped
        |> Enum.filter(fn {{series, _}, _} -> series == id end)
        |> Enum.map(fn {{_, start_at}, bucket_rows} -> point(bucket_rows, start_at, spec) end)
        |> order(spec.order)

      %{"schema" => "wtr.query-series.v1", "id" => id, "unit" => spec.unit, "points" => points}
    end)
  end

  defp bucket_start(row, spec),
    do: spec.from_at + div(row.event_at - spec.from_at, spec.bucket_ms) * spec.bucket_ms

  defp point(rows, start_at, spec) do
    last = Enum.max_by(rows, &{&1.event_at, &1.identity})

    %{
      "schema" => "wtr.query-point.v1",
      "start_at" => start_at,
      "end_at" => min(start_at + spec.bucket_ms, spec.to_at),
      "value" => aggregate_value(rows, spec.aggregation, last),
      "sample_count" => length(rows),
      "last_event_at" => last.event_at,
      "last_row_identity" => last.identity
    }
  end

  defp aggregate_value(rows, :count, _last), do: length(rows)
  defp aggregate_value(rows, :min, _last), do: rows |> Enum.map(& &1.value) |> Enum.min()
  defp aggregate_value(rows, :max, _last), do: rows |> Enum.map(& &1.value) |> Enum.max()

  defp aggregate_value(rows, :mean, _last),
    do: Enum.sum(Enum.map(rows, & &1.value)) / length(rows)

  defp aggregate_value(_rows, :last, last), do: last.value

  defp order(points, :ascending),
    do: Enum.sort_by(points, &{&1["start_at"], &1["last_row_identity"]})

  defp order(points, :descending),
    do: Enum.sort_by(points, &{&1["start_at"], &1["last_row_identity"]}, :desc)
end
