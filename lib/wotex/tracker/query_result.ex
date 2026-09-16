defmodule Wotex.Tracker.QueryResult do
  @moduledoc "A content-identified deterministic analytics result with disclosed exclusions."
  alias Wotex.Tracker.{Admission, Error, Limits, QuerySpec}

  @fields ~w(spec snapshot series scanned_rows selected_rows qualified_rows excluded_unavailable excluded_quality)a
  @serialized_fields ~w(schema algorithm spec snapshot series scanned_rows selected_rows qualified_rows excluded_unavailable excluded_quality downsampling continuity identity)
  @series_fields ~w(schema id unit points)
  @point_fields ~w(schema start_at end_at value sample_count last_event_at last_row_identity)
  @maximum_rows 100_000
  @maximum_safe_integer 9_007_199_254_740_991
  @type t :: %__MODULE__{}
  @enforce_keys @fields ++ [:identity]
  defstruct @enforce_keys

  @doc "Admits bounded series and binds the exact query, snapshot and disclosure counts."
  @spec new(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(input, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         :ok <- Admission.fields(input, @fields),
         {:ok, spec} <- QuerySpec.validate(input.spec, options),
         :ok <- Admission.id(input.snapshot, limits),
         :ok <- counts(input),
         :ok <- series(input.series, spec, limits, input.qualified_rows),
         {:ok, identity} <-
           Admission.digest(result_map(input, spec, options), result_limits(limits)) do
      {:ok, struct!(__MODULE__, Map.merge(input, %{spec: spec, identity: identity}))}
    else
      error -> error
    end
  end

  @doc "Revalidates the result and rejects changed points, counts or identity."
  @spec validate(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(value, options \\ [])

  def validate(%__MODULE__{} = value, options) do
    with {:ok, admitted} <- new(Map.take(value, @fields), options) do
      if admitted === value, do: {:ok, value}, else: Admission.fail(:conflict)
    end
  end

  def validate(_, _), do: Admission.fail(:invalid_input)

  @doc "Projects the complete deterministic result to closed native JSON."
  @spec to_map(term(), term()) :: {:ok, map()} | {:error, Error.t()}
  def to_map(value, options \\ []) do
    with {:ok, result} <- validate(value, options) do
      {:ok, Map.put(result_map(result, result.spec, options), "identity", result.identity)}
    end
  end

  @doc "Restores and revalidates a result from closed native JSON."
  @spec from_map(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(document, options \\ []) do
    with true <- exact_fields?(document, @serialized_fields),
         true <-
           document["schema"] == "wtr.query-result.v1" and
             document["algorithm"] == "absolute-utc-buckets-v1" and
             document["downsampling"] == "requested_bucket_aggregation" and
             document["continuity"] == "gaps_preserved",
         {:ok, spec} <- QuerySpec.from_map(document["spec"], options),
         {:ok, result} <-
           new(
             %{
               spec: spec,
               snapshot: document["snapshot"],
               series: document["series"],
               scanned_rows: document["scanned_rows"],
               selected_rows: document["selected_rows"],
               qualified_rows: document["qualified_rows"],
               excluded_unavailable: document["excluded_unavailable"],
               excluded_quality: document["excluded_quality"]
             },
             options
           ),
         true <- result.identity == document["identity"] do
      {:ok, result}
    else
      false -> Admission.fail(:conflict)
      error -> error
    end
  end

  defp counts(input) do
    values = [
      input.scanned_rows,
      input.selected_rows,
      input.qualified_rows,
      input.excluded_unavailable,
      input.excluded_quality
    ]

    if Enum.all?(values, &(is_integer(&1) and &1 in 0..@maximum_safe_integer)) and
         input.scanned_rows <= @maximum_rows and
         input.selected_rows <= input.scanned_rows and
         input.qualified_rows + input.excluded_unavailable + input.excluded_quality ==
           input.selected_rows do
      :ok
    else
      Admission.fail(:invalid_input)
    end
  end

  defp series(values, spec, limits, qualified_rows) when is_list(values) do
    with {:ok, ids} <- series_ids(values),
         true <- ids == spec.series,
         :ok <- Admission.each(values, &series(&1, spec, limits)),
         true <- sample_count(values) == qualified_rows do
      :ok
    else
      false -> Admission.fail(:conflict)
      error -> error
    end
  end

  defp series(_, _, _, _), do: Admission.fail(:invalid_input)

  defp series(value, spec, limits) when is_map(value) and not is_struct(value) do
    with true <- exact_fields?(value, @series_fields),
         true <- value["schema"] == "wtr.query-series.v1" and value["unit"] == spec.unit,
         :ok <- Admission.id(value["id"], limits),
         true <- is_list(value["points"]) and length(value["points"]) <= spec.max_points,
         :ok <- Admission.each(value["points"], &point(&1, spec, limits)),
         true <- unique_bucket_starts?(value["points"]),
         true <- ordered?(value["points"], spec.order) do
      :ok
    else
      false -> Admission.fail(:conflict)
      error -> error
    end
  end

  defp series(_, _, _), do: Admission.fail(:invalid_input)

  defp series_ids(values) do
    Enum.reduce_while(values, {:ok, []}, fn
      %{"id" => id}, {:ok, ids} -> {:cont, {:ok, [id | ids]}}
      _, _ -> {:halt, Admission.fail(:invalid_input)}
    end)
    |> then(fn
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      error -> error
    end)
  end

  defp point(value, spec, limits) do
    with true <- exact_fields?(value, @point_fields),
         true <- value["schema"] == "wtr.query-point.v1",
         true <- is_integer(value["start_at"]) and is_integer(value["end_at"]),
         true <- value["start_at"] >= spec.from_at and value["end_at"] <= spec.to_at,
         true <- rem(value["start_at"] - spec.from_at, spec.bucket_ms) == 0,
         true <- value["end_at"] == min(value["start_at"] + spec.bucket_ms, spec.to_at),
         true <- is_integer(value["sample_count"]) and value["sample_count"] > 0,
         true <- aggregate_value?(value["value"], value["sample_count"], spec.aggregation),
         true <-
           is_integer(value["last_event_at"]) and value["last_event_at"] >= value["start_at"] and
             value["last_event_at"] < value["end_at"],
         :ok <- Admission.id(value["last_row_identity"], limits) do
      :ok
    else
      false -> Admission.fail(:conflict)
      error -> error
    end
  end

  defp ordered?([], _), do: true

  defp ordered?(points, :ascending),
    do: points == Enum.sort_by(points, &{&1["start_at"], &1["last_row_identity"]})

  defp ordered?(points, :descending),
    do: points == Enum.sort_by(points, &{&1["start_at"], &1["last_row_identity"]}, :desc)

  defp unique_bucket_starts?(points) do
    starts = Enum.map(points, & &1["start_at"])
    Enum.uniq(starts) == starts
  end

  defp aggregate_value?(value, sample_count, :count), do: value == sample_count
  defp aggregate_value?(value, _sample_count, _aggregation), do: finite_number?(value)

  defp finite_number?(value) when is_integer(value), do: true
  defp finite_number?(value) when is_float(value), do: value > -1.0e308 and value < 1.0e308
  defp finite_number?(_), do: false

  defp sample_count(series) do
    Enum.reduce(series, 0, fn value, total ->
      total + Enum.reduce(value["points"], 0, &(&1["sample_count"] + &2))
    end)
  end

  defp result_map(input, spec, options) do
    {:ok, spec_document} = QuerySpec.to_map(spec, options)

    %{
      "schema" => "wtr.query-result.v1",
      "algorithm" => "absolute-utc-buckets-v1",
      "spec" => spec_document,
      "snapshot" => input.snapshot,
      "series" => input.series,
      "scanned_rows" => input.scanned_rows,
      "selected_rows" => input.selected_rows,
      "qualified_rows" => input.qualified_rows,
      "excluded_unavailable" => input.excluded_unavailable,
      "excluded_quality" => input.excluded_quality,
      "downsampling" => "requested_bucket_aggregation",
      "continuity" => "gaps_preserved"
    }
  end

  defp result_limits(limits) do
    limits
    |> Limits.material()
    |> Keyword.put(:max_collection_size, 1_000)
  end

  defp exact_fields?(value, fields),
    do:
      is_map(value) and not is_struct(value) and
        Enum.sort(Map.keys(value)) == Enum.sort(fields)
end
