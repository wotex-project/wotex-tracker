defmodule Wotex.Tracker.Service.OperationalTelemetry do
  @moduledoc """
  Closed operational `:telemetry` events emitted by the service and host adapters.

  Measurements use integer microseconds and row counts. Metadata is deliberately
  low cardinality: it never contains a scope, principal, record ID, position,
  prompt, payload or arbitrary user string. Loading this module installs no
  handler and starts no process.
  """

  @request [:wotex, :tracker, :service, :request, :stop]
  @query [:wotex, :tracker, :service, :query, :stop]
  @ingest [:wotex, :tracker, :service, :ingest, :stop]
  @store [:wotex, :tracker, :service, :store, :stop]
  @queue [:wotex, :tracker, :service, :queue, :stop]
  @publication [:wotex, :tracker, :service, :publication, :stop]
  @resource [:wotex, :tracker, :service, :resource, :stop]
  @runtime [:wotex, :tracker, :service, :runtime, :sample]
  @browser_render [:wotex, :tracker, :browser, :render, :stop]
  @outcomes ~w(ok dropped rejected conflict overloaded deadline unavailable unknown)a
  @request_operations ~w(health contract capabilities mutation resource events stream property analytics saved_query unknown)a
  @aggregations ~w(count min max mean last)a
  @ingest_stages ~w(admission decode)a
  @store_operations ~w(mutation rule_state rule_event)a
  @queue_operations ~w(enqueue claim complete cleanup)a
  @publication_operations ~w(lookup latest confirm)a
  @resources ~w(store)a
  @resource_operations ~w(readiness checkpoint backup)a
  @render_outcomes ~w(ok unavailable)a

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
      },
      %{
        event: @ingest,
        name: "ingest.stop",
        measurements: %{duration_us: :microsecond},
        metadata: %{stage: @ingest_stages, outcome: @outcomes}
      },
      %{
        event: @store,
        name: "store.stop",
        measurements: %{duration_us: :microsecond},
        metadata: %{operation: @store_operations, outcome: @outcomes}
      },
      %{
        event: @queue,
        name: "queue.stop",
        measurements: %{
          duration_us: :microsecond,
          depth_items: :count,
          depth_bytes: :byte,
          affected_items: :count,
          dropped_items: :count
        },
        metadata: %{operation: @queue_operations, outcome: @outcomes}
      },
      %{
        event: @publication,
        name: "publication.stop",
        measurements: %{duration_us: :microsecond},
        metadata: %{operation: @publication_operations, outcome: @outcomes}
      },
      %{
        event: @resource,
        name: "resource.stop",
        measurements: %{duration_us: :microsecond},
        metadata: %{resource: @resources, operation: @resource_operations, outcome: @outcomes}
      },
      %{
        event: @runtime,
        name: "runtime.sample",
        measurements: %{beam_memory_bytes: :byte, process_count: :count, port_count: :count},
        metadata: %{runtime: [:beam]}
      },
      %{
        event: @browser_render,
        name: "render.stop",
        measurements: %{duration_us: :microsecond},
        metadata: %{surface: [:browser], outcome: @render_outcomes}
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
  def ingest(stage, result, started) when stage in @ingest_stages and is_integer(started),
    do: stop(@ingest, %{stage: stage}, result, started)

  @doc false
  def store(operation, result, started)
      when operation in @store_operations and is_integer(started),
      do: stop(@store, %{operation: operation}, result, started)

  @doc false
  def queue(operation, result, measurements, started)
      when operation in @queue_operations and is_map(measurements) and is_integer(started) do
    execute(
      @queue,
      Map.put(measurements, :duration_us, elapsed(started)),
      %{operation: operation, outcome: queue_outcome(result)}
    )
  end

  @doc false
  def publication(operation, result, started)
      when operation in @publication_operations and is_integer(started),
      do: stop(@publication, %{operation: operation}, result, started)

  @doc false
  def resource(resource, operation, result, started)
      when resource in @resources and operation in @resource_operations and is_integer(started),
      do: stop(@resource, %{resource: resource, operation: operation}, result, started)

  @doc false
  def runtime_sample do
    execute(
      @runtime,
      %{
        beam_memory_bytes: :erlang.memory(:total),
        process_count: :erlang.system_info(:process_count),
        port_count: :erlang.system_info(:port_count)
      },
      %{runtime: :beam}
    )
  end

  @doc "Records one completed browser render without forwarding LiveView metadata."
  def browser_render(outcome, duration)
      when outcome in @render_outcomes and is_integer(duration) and duration >= 0 do
    execute(
      @browser_render,
      %{duration_us: System.convert_time_unit(duration, :native, :microsecond)},
      %{surface: :browser, outcome: outcome}
    )
  end

  @doc false
  def event_names,
    do: [
      @request,
      @query,
      @ingest,
      @store,
      @queue,
      @publication,
      @resource,
      @runtime,
      @browser_render
    ]

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

  def sample(@ingest, measurements, metadata),
    do: sample("ingest.stop", measurements, metadata, [:duration_us], [:stage, :outcome])

  def sample(@store, measurements, metadata),
    do: sample("store.stop", measurements, metadata, [:duration_us], [:operation, :outcome])

  def sample(@queue, measurements, metadata),
    do:
      sample(
        "queue.stop",
        measurements,
        metadata,
        [:duration_us, :depth_items, :depth_bytes, :affected_items, :dropped_items],
        [:operation, :outcome]
      )

  def sample(@publication, measurements, metadata),
    do: sample("publication.stop", measurements, metadata, [:duration_us], [:operation, :outcome])

  def sample(@resource, measurements, metadata),
    do:
      sample(
        "resource.stop",
        measurements,
        metadata,
        [:duration_us],
        [:resource, :operation, :outcome]
      )

  def sample(@runtime, measurements, metadata),
    do:
      sample(
        "runtime.sample",
        measurements,
        metadata,
        [:beam_memory_bytes, :process_count, :port_count],
        [:runtime]
      )

  def sample(@browser_render, measurements, metadata),
    do: sample("render.stop", measurements, metadata, [:duration_us], [:surface, :outcome])

  def sample(_, _, _), do: {:error, :invalid_sample}

  defp execute(event, measurements, metadata) do
    :telemetry.execute(event, measurements, metadata)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp stop(event, metadata, result, started),
    do:
      execute(
        event,
        %{duration_us: elapsed(started)},
        Map.put(metadata, :outcome, outcome(result))
      )

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

  defp valid_metadata?("ingest.stop", metadata),
    do: metadata.stage in @ingest_stages and metadata.outcome in @outcomes

  defp valid_metadata?("store.stop", metadata),
    do: metadata.operation in @store_operations and metadata.outcome in @outcomes

  defp valid_metadata?("queue.stop", metadata),
    do: metadata.operation in @queue_operations and metadata.outcome in @outcomes

  defp valid_metadata?("publication.stop", metadata),
    do: metadata.operation in @publication_operations and metadata.outcome in @outcomes

  defp valid_metadata?("resource.stop", metadata),
    do:
      metadata.resource in @resources and metadata.operation in @resource_operations and
        metadata.outcome in @outcomes

  defp valid_metadata?("runtime.sample", metadata), do: metadata.runtime == :beam

  defp valid_metadata?("render.stop", metadata),
    do: metadata.surface == :browser and metadata.outcome in @render_outcomes

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
  defp outcome(:ok), do: :ok
  defp outcome({:error, :overloaded}), do: :overloaded
  defp outcome({:error, :deadline_exceeded}), do: :deadline

  defp outcome({:error, reason}) when reason in [:conflict, :forward_conflict, :superseded],
    do: :conflict

  defp outcome({:error, reason})
       when reason in [:storage_unavailable, :storage_full, :busy, :unknown],
       do: :unavailable

  defp outcome({:error, _}), do: :rejected
  defp outcome(_), do: :unknown

  defp queue_outcome({:ok, %{"disposition" => "dropped"}}), do: :dropped
  defp queue_outcome(result), do: outcome(result)
end
