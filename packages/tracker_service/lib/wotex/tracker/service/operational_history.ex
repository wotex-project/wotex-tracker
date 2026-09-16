defmodule Wotex.Tracker.Service.OperationalHistory do
  @moduledoc """
  Explicitly supervised bounded local history for service telemetry.

  Samples are volatile ETS data. Restarting the owner clears every sample and
  changes the epoch. Retention and capacity are enforced during insertion and
  reads; collector loss never changes an admitted observation or alarm decision.
  """
  use GenServer

  alias Wotex.Tracker.Service.{Codec, OperationalTelemetry}

  @default_max_samples 2_048
  @default_retention_ms 900_000
  @events ~w(request.stop query.stop ingest.stop store.stop queue.stop publication.stop resource.stop runtime.sample)

  @doc "Starts an isolated collector and attaches only the documented events."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []), do: GenServer.start_link(__MODULE__, options)

  @doc "Returns one coherent retained snapshot from the current collector epoch."
  @spec snapshot(pid(), keyword()) :: {:ok, map()} | {:error, :invalid_query | :unavailable}
  def snapshot(pid, options \\ []) when is_pid(pid) and is_list(options) do
    GenServer.call(pid, {:snapshot, options})
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc "Reads a bounded page pinned to one collector epoch and sequence high-water mark."
  @spec page(pid(), keyword()) ::
          {:ok, map()}
          | {:error, :invalid_query | :invalid_cursor | :cursor_expired | :unavailable}
  def page(pid, options \\ []) when is_pid(pid) and is_list(options) do
    GenServer.call(pid, {:page, options})
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @impl true
  def init(options) do
    with {:ok, config} <- config(options),
         table = :ets.new(__MODULE__, [:ordered_set, :protected]),
         handler = {__MODULE__, make_ref()},
         :ok <-
           :telemetry.attach_many(
             handler,
             OperationalTelemetry.event_names(),
             &__MODULE__.handle_event/4,
             self()
           ) do
      {:ok,
       Map.merge(config, %{
         table: table,
         handler: handler,
         epoch: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false),
         sequence: 0
       })}
    else
      _ -> {:stop, :invalid_options}
    end
  end

  @doc false
  def handle_event(event, measurements, metadata, owner),
    do: send(owner, {:operational_sample, event, measurements, metadata})

  @impl true
  def handle_info({:operational_sample, event, measurements, metadata}, state) do
    case {OperationalTelemetry.sample(event, measurements, metadata), current_time(state)} do
      {{:ok, sample}, {:ok, now}} -> {:noreply, insert(state, sample, now)}
      {{:error, _}, _} -> {:noreply, state}
      _ -> {:noreply, state}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def handle_call({:snapshot, options}, _from, state) do
    case {query(options), current_time(state)} do
      {{:ok, query}, {:ok, now}} ->
        state = prune(state, now)
        samples = samples(state.table, query)

        {:reply,
         {:ok,
          %{
            "schema" => "wtr.operational-history.v1",
            "epoch" => state.epoch,
            "captured_at" => now,
            "volatile" => true,
            "samples" => samples
          }}, state}

      {{:error, _} = error, _} ->
        {:reply, error, state}

      _ ->
        {:reply, {:error, :unavailable}, state}
    end
  end

  def handle_call({:page, options}, _from, state) do
    case {page_query(options), current_time(state)} do
      {{:ok, query}, {:ok, now}} ->
        state = prune(state, now)
        {:reply, page_result(state, query, now), state}

      {{:error, _} = error, _} ->
        {:reply, error, state}

      _ ->
        {:reply, {:error, :unavailable}, state}
    end
  end

  @impl true
  def terminate(_, state) do
    :telemetry.detach(state.handler)
    :ok
  end

  defp insert(state, sample, now) do
    state = prune(state, now)
    sequence = state.sequence + 1

    true =
      :ets.insert(
        state.table,
        {sequence, Map.merge(sample, %{"sequence" => sequence, "observed_at" => now})}
      )

    trim(state.table, state.max_samples)
    %{state | sequence: sequence}
  end

  defp prune(state, now) do
    cutoff = now - state.retention_ms

    state.table
    |> :ets.tab2list()
    |> Enum.each(fn {sequence, %{"observed_at" => observed_at}} ->
      if observed_at <= cutoff, do: :ets.delete(state.table, sequence)
    end)

    state
  end

  defp trim(table, maximum) do
    if :ets.info(table, :size) > maximum do
      :ets.delete(table, :ets.first(table))
      trim(table, maximum)
    end
  end

  defp samples(table, %{event: event, limit: limit}) do
    table
    |> :ets.tab2list()
    |> Enum.map(&elem(&1, 1))
    |> Enum.filter(&(is_nil(event) or &1["event"] == event))
    |> Enum.take(-limit)
  end

  defp page_result(state, query, now) do
    with {:ok, after_sequence, through} <- page_position(state, query) do
      matches =
        state.table
        |> :ets.tab2list()
        |> Enum.filter(fn {sequence, sample} ->
          sequence > after_sequence and sequence <= through and
            (is_nil(query.event) or sample["event"] == query.event)
        end)
        |> Enum.take(query.limit + 1)

      items = matches |> Enum.take(query.limit) |> Enum.map(&elem(&1, 1))

      cursor =
        if length(matches) > query.limit do
          %{
            "schema" => "wtr.operational-cursor.v1",
            "epoch" => state.epoch,
            "after" => List.last(items)["sequence"],
            "through" => through,
            "event" => query.event,
            "limit" => query.limit
          }
        end

      {:ok,
       %{
         "schema" => "wtr.operational-page.v1",
         "epoch" => state.epoch,
         "captured_at" => now,
         "volatile" => true,
         "through" => through,
         "samples" => items,
         "cursor" => cursor
       }}
    end
  end

  defp page_position(state, %{cursor: nil}) do
    earliest = earliest(state)
    {:ok, earliest - 1, state.sequence}
  end

  defp page_position(state, %{cursor: cursor, event: event, limit: limit}) do
    case cursor do
      %{
        "schema" => "wtr.operational-cursor.v1",
        "epoch" => epoch,
        "after" => after_sequence,
        "through" => through,
        "event" => ^event,
        "limit" => ^limit
      }
      when map_size(cursor) == 6 and is_integer(after_sequence) and after_sequence >= 0 and
             is_integer(through) and through >= after_sequence ->
        resume_position(state, epoch, after_sequence, through)

      _ ->
        {:error, :invalid_cursor}
    end
  end

  defp resume_position(state, epoch, after_sequence, through) do
    cond do
      epoch != state.epoch or through > state.sequence -> {:error, :invalid_cursor}
      after_sequence < earliest(state) - 1 -> {:error, :cursor_expired}
      true -> {:ok, after_sequence, through}
    end
  end

  defp earliest(state) do
    case :ets.first(state.table) do
      :"$end_of_table" -> state.sequence + 1
      sequence -> sequence
    end
  end

  defp page_query(options) do
    if Keyword.keyword?(options) and length(options) == map_size(Map.new(options)) and
         Enum.all?(Keyword.keys(options), &(&1 in [:event, :limit, :cursor])) do
      event = Keyword.get(options, :event)
      limit = Keyword.get(options, :limit, 100)

      if (is_nil(event) or event in @events) and is_integer(limit) and limit in 1..1_000,
        do: {:ok, %{event: event, limit: limit, cursor: Keyword.get(options, :cursor)}},
        else: {:error, :invalid_query}
    else
      {:error, :invalid_query}
    end
  end

  defp query(options) do
    if Keyword.keyword?(options) and
         Enum.all?(Keyword.keys(options), &(&1 in [:event, :limit])) do
      event = Keyword.get(options, :event)
      limit = Keyword.get(options, :limit, 100)

      if (is_nil(event) or event in @events) and
           is_integer(limit) and limit in 1..1_000,
         do: {:ok, %{event: event, limit: limit}},
         else: {:error, :invalid_query}
    else
      {:error, :invalid_query}
    end
  end

  defp config(options) do
    if Keyword.keyword?(options) and
         Enum.all?(Keyword.keys(options), &(&1 in [:max_samples, :retention_ms, :clock])) do
      config = %{
        max_samples: Keyword.get(options, :max_samples, @default_max_samples),
        retention_ms: Keyword.get(options, :retention_ms, @default_retention_ms),
        clock: Keyword.get(options, :clock, fn -> System.system_time(:millisecond) end)
      }

      if config.max_samples in 1..10_000 and config.retention_ms in 1..86_400_000 and
           is_function(config.clock, 0),
         do: {:ok, config},
         else: {:error, :invalid_options}
    else
      {:error, :invalid_options}
    end
  end

  defp valid_time?(value), do: Codec.time?(value)

  defp current_time(state) do
    value = state.clock.()
    if valid_time?(value), do: {:ok, value}, else: {:error, :unavailable}
  rescue
    _ -> {:error, :unavailable}
  end
end
