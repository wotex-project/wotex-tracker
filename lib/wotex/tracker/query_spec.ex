defmodule Wotex.Tracker.QuerySpec do
  @moduledoc """
  A closed immutable query over qualified numeric measurement history.

  The first query revision uses absolute Unix-millisecond windows and UTC-aligned
  buckets. It cannot carry SQL, code, tenant scope, module names or destinations.
  """
  alias Wotex.Tracker.{Admission, Error, Limits}

  @fields ~w(id revision dataset measurement unit series qualities from_at to_at timezone bucket_ms aggregation order max_points)a
  @serialized_fields ~w(schema algorithm id revision dataset measurement unit series qualities from_at to_at timezone bucket_ms aggregation order max_points window_semantics missing_values identity)
  @aggregations ~w(count min max mean last)a
  @qualities ~w(valid suspect)a
  @maximum_window_ms 2_678_400_000
  @type t :: %__MODULE__{}
  @enforce_keys @fields ++ [:identity]
  defstruct @enforce_keys

  @doc "Admits an absolute UTC numeric query with finite series, row and point budgets."
  @spec new(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(input, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         :ok <- Admission.fields(input, @fields),
         :ok <-
           Admission.each(
             [input.id, input.revision, input.measurement, input.unit],
             &Admission.id(&1, limits)
           ),
         true <- input.dataset == :measurements,
         :ok <- unique_ids(input.series, 8, limits),
         :ok <- qualities(input.qualities),
         true <- time?(input.from_at) and time?(input.to_at),
         true <- input.to_at > input.from_at,
         window = input.to_at - input.from_at,
         true <- window <= @maximum_window_ms,
         true <- input.timezone == "Etc/UTC",
         true <- is_integer(input.bucket_ms) and input.bucket_ms in 1..@maximum_window_ms,
         true <- input.aggregation in @aggregations,
         true <- input.order in [:ascending, :descending],
         true <- is_integer(input.max_points) and input.max_points in 1..1_000,
         true <- bucket_count(window, input.bucket_ms) <= input.max_points,
         {:ok, identity} <- Admission.digest(spec_map(input), Limits.json(limits)) do
      {:ok, struct!(__MODULE__, Map.put(input, :identity, identity))}
    else
      false -> Admission.fail(:invalid_input)
      error -> error
    end
  end

  @doc "Revalidates every query field and its content identity."
  @spec validate(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(value, options \\ [])

  def validate(%__MODULE__{} = value, options) do
    with {:ok, admitted} <- new(Map.take(value, @fields), options) do
      if admitted === value, do: {:ok, value}, else: Admission.fail(:conflict)
    end
  end

  def validate(_, _), do: Admission.fail(:invalid_input)

  @doc "Projects the query to closed native JSON for APIs and saved dashboards."
  @spec to_map(term(), term()) :: {:ok, map()} | {:error, Error.t()}
  def to_map(value, options \\ []) do
    with {:ok, spec} <- validate(value, options) do
      {:ok, Map.put(spec_map(spec), "identity", spec.identity)}
    end
  end

  @doc "Restores and revalidates a query from closed native JSON."
  @spec from_map(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(document, options \\ []) do
    with true <- exact_fields?(document, @serialized_fields),
         true <-
           document["schema"] == "wtr.query-spec.v1" and
             document["algorithm"] == "absolute-utc-buckets-v1" and
             document["dataset"] == "measurements" and
             document["window_semantics"] == "from_inclusive_to_exclusive" and
             document["missing_values"] == "excluded_and_disclosed",
         {:ok, aggregation} <- aggregation_atom(document["aggregation"]),
         {:ok, order} <- order_atom(document["order"]),
         {:ok, qualities} <- quality_atoms(document["qualities"]),
         {:ok, spec} <-
           new(
             %{
               id: document["id"],
               revision: document["revision"],
               dataset: :measurements,
               measurement: document["measurement"],
               unit: document["unit"],
               series: document["series"],
               qualities: qualities,
               from_at: document["from_at"],
               to_at: document["to_at"],
               timezone: document["timezone"],
               bucket_ms: document["bucket_ms"],
               aggregation: aggregation,
               order: order,
               max_points: document["max_points"]
             },
             options
           ),
         true <- spec.identity == document["identity"] do
      {:ok, spec}
    else
      false -> Admission.fail(:conflict)
      error -> error
    end
  end

  defp unique_ids(values, maximum, limits) when is_list(values) do
    with true <- length(values) in 1..maximum,
         true <- length(Enum.uniq(values)) == length(values),
         :ok <- Admission.each(values, &Admission.id(&1, limits)) do
      :ok
    else
      false -> Admission.fail(:invalid_input)
      error -> error
    end
  end

  defp unique_ids(_, _, _), do: Admission.fail(:invalid_input)

  defp qualities(values) when is_list(values) do
    if values != [] and Enum.uniq(values) == values and Enum.all?(values, &(&1 in @qualities)),
      do: :ok,
      else: Admission.fail(:invalid_input)
  end

  defp qualities(_), do: Admission.fail(:invalid_input)

  defp time?(value), do: is_integer(value) and value in 0..9_007_199_254_740_991
  defp bucket_count(window, bucket), do: div(window + bucket - 1, bucket)

  defp spec_map(input),
    do: %{
      "schema" => "wtr.query-spec.v1",
      "algorithm" => "absolute-utc-buckets-v1",
      "id" => input.id,
      "revision" => input.revision,
      "dataset" => "measurements",
      "measurement" => input.measurement,
      "unit" => input.unit,
      "series" => input.series,
      "qualities" => Enum.map(input.qualities, &Atom.to_string/1),
      "from_at" => input.from_at,
      "to_at" => input.to_at,
      "timezone" => input.timezone,
      "bucket_ms" => input.bucket_ms,
      "aggregation" => Atom.to_string(input.aggregation),
      "order" => Atom.to_string(input.order),
      "max_points" => input.max_points,
      "window_semantics" => "from_inclusive_to_exclusive",
      "missing_values" => "excluded_and_disclosed"
    }

  defp aggregation_atom("count"), do: {:ok, :count}
  defp aggregation_atom("min"), do: {:ok, :min}
  defp aggregation_atom("max"), do: {:ok, :max}
  defp aggregation_atom("mean"), do: {:ok, :mean}
  defp aggregation_atom("last"), do: {:ok, :last}
  defp aggregation_atom(_), do: Admission.fail(:invalid_input)

  defp order_atom("ascending"), do: {:ok, :ascending}
  defp order_atom("descending"), do: {:ok, :descending}
  defp order_atom(_), do: Admission.fail(:invalid_input)

  defp quality_atoms(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case value do
        "valid" -> {:cont, {:ok, [:valid | acc]}}
        "suspect" -> {:cont, {:ok, [:suspect | acc]}}
        _ -> {:halt, Admission.fail(:invalid_input)}
      end
    end)
    |> then(fn
      {:ok, result} -> {:ok, Enum.reverse(result)}
      error -> error
    end)
  end

  defp quality_atoms(_), do: Admission.fail(:invalid_input)

  defp exact_fields?(value, fields),
    do:
      is_map(value) and not is_struct(value) and
        Enum.sort(Map.keys(value)) == Enum.sort(fields)
end
