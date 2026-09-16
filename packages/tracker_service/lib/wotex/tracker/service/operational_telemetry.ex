defmodule Wotex.Tracker.Service.OperationalTelemetry do
  @moduledoc """
  Closed operational `:telemetry` events emitted by the service.

  Measurements use integer microseconds and row counts. Metadata is deliberately
  low cardinality: it never contains a scope, principal, record ID, position,
  prompt, payload or arbitrary user string. Loading this module installs no
  handler and starts no process.
  """

  @request [:wotex, :tracker, :service, :request, :stop]
  @query [:wotex, :tracker, :service, :query, :stop]
  @outcomes ~w(ok rejected conflict overloaded deadline unavailable unknown)a
  @request_operations ~w(health contract capabilities mutation resource events stream property analytics saved_query unknown)a
  @aggregations ~w(count min max mean last)a

  @doc "Returns the complete event vocabulary and its measurement units."
  def contracts do
    [
      %{
        event: @request,
        name: "request.stop",
        measurements: %{duration_us: :microsecond},
        metadata: %{operation: @request_operations, outcome: @outcomes}
      },
      %{
        event: @query,
        name: "query.stop",
        measurements: %{duration_us: :microsecond, scanned_rows: :row},
        metadata: %{aggregation: @aggregations, outcome: @outcomes}
      }
    ]
  end

  @doc false
  def request(operation, status, started)
      when operation in @request_operations and is_integer(status) and is_integer(started) do
    execute(
      @request,
      %{duration_us: elapsed(started)},
      %{operation: operation, outcome: http_outcome(status)}
    )
  end

  @doc false
  def query(aggregation, result, started)
      when aggregation in @aggregations and is_integer(started) do
    execute(
      @query,
      %{duration_us: elapsed(started), scanned_rows: scanned_rows(result)},
      %{aggregation: aggregation, outcome: outcome(result)}
    )
  end

  @doc false
  def event_names, do: [@request, @query]

  @doc false
  def sample(@request, measurements, metadata),
    do: sample("request.stop", measurements, metadata, [:duration_us], [:operation, :outcome])

  def sample(@query, measurements, metadata),
    do:
      sample(
        "query.stop",
        measurements,
        metadata,
        [:duration_us, :scanned_rows],
        [:aggregation, :outcome]
      )

  def sample(_, _, _), do: {:error, :invalid_sample}

  defp execute(event, measurements, metadata) do
    :telemetry.execute(event, measurements, metadata)
    :ok
  end

  defp sample(name, measurements, metadata, measurement_keys, metadata_keys) do
    with true <- exact?(measurements, measurement_keys),
         true <- exact?(metadata, metadata_keys),
         true <- Enum.all?(measurements, fn {_, value} -> is_integer(value) and value >= 0 end),
         true <- valid_metadata?(name, metadata) do
      {:ok,
       %{
         "event" => name,
         "measurements" =>
           Map.new(measurements, fn {key, value} -> {Atom.to_string(key), value} end),
         "metadata" =>
           Map.new(metadata, fn {key, value} -> {Atom.to_string(key), Atom.to_string(value)} end)
       }}
    else
      _ -> {:error, :invalid_sample}
    end
  end

  defp valid_metadata?("request.stop", metadata),
    do: metadata.operation in @request_operations and metadata.outcome in @outcomes

  defp valid_metadata?("query.stop", metadata),
    do: metadata.aggregation in @aggregations and metadata.outcome in @outcomes

  defp exact?(value, keys),
    do: is_map(value) and not is_struct(value) and Enum.sort(Map.keys(value)) == Enum.sort(keys)

  defp elapsed(started),
    do:
      System.monotonic_time()
      |> Kernel.-(started)
      |> System.convert_time_unit(:native, :microsecond)
      |> max(0)

  defp scanned_rows({:ok, %{"scanned_rows" => rows}}) when is_integer(rows) and rows >= 0,
    do: rows

  defp scanned_rows(_), do: 0

  defp http_outcome(status) when status in 200..399, do: :ok
  defp http_outcome(status) when status in 400..499, do: :rejected
  defp http_outcome(_), do: :unavailable

  defp outcome({:ok, _}), do: :ok
  defp outcome({:error, :overloaded}), do: :overloaded
  defp outcome({:error, :deadline_exceeded}), do: :deadline
  defp outcome({:error, :conflict}), do: :conflict
  defp outcome({:error, reason}) when reason in [:storage_unavailable, :unknown], do: :unavailable
  defp outcome({:error, _}), do: :rejected
  defp outcome(_), do: :unknown
end
