defmodule Wotex.Tracker.Service.OperationalExporter.State do
  @moduledoc false

  @derive {Inspect,
           only: [
             :collector,
             :adapter,
             :interval_ms,
             :retry_ms,
             :timeout_ms,
             :batch_size,
             :checkpoint
           ]}
  @enforce_keys [
    :collector,
    :adapter,
    :context,
    :interval_ms,
    :retry_ms,
    :timeout_ms,
    :batch_size
  ]
  defstruct @enforce_keys ++ [checkpoint: nil, in_flight: nil, timer: nil]
end

defmodule Wotex.Tracker.Service.OperationalExporter do
  @moduledoc """
  Optional bounded asynchronous delivery of volatile operational history.

  A host starts this process with an `OperationalHistory` collector and one
  `OperationalExportAdapter`. Only one batch is retained in memory. A failed,
  crashed or timed-out adapter is retried from the last acknowledged checkpoint;
  collector retention or restart is disclosed in the next batch. Export work
  never runs in a telemetry handler or the collector process.
  """

  use GenServer

  alias Wotex.Tracker.Service.OperationalExporter.State
  alias Wotex.Tracker.Service.OperationalHistory

  @default_interval_ms 5_000
  @default_retry_ms 1_000
  @default_timeout_ms 5_000
  @default_batch_size 100

  @doc "Starts one explicitly configured exporter."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    with {:ok, config} <- config(options), do: GenServer.start_link(__MODULE__, config)
  end

  @doc "Returns non-secret progress for host diagnostics."
  @spec status(pid()) :: {:ok, map()} | {:error, :unavailable}
  def status(pid) when is_pid(pid) do
    GenServer.call(pid, :status)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @impl true
  def init(config), do: {:ok, config, {:continue, :export}}

  @impl true
  def handle_continue(:export, state), do: {:noreply, export(state)}

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     {:ok,
      %{
        "checkpoint" => state.checkpoint,
        "delivering" => not is_nil(state.in_flight)
      }}, state}
  end

  @impl true
  def handle_info(:export, %{in_flight: nil} = state), do: {:noreply, export(state)}

  def handle_info({:delivery, reference, :ok}, %{in_flight: %{reference: reference}} = state) do
    batch = state.in_flight.batch
    state = finish_delivery(state)
    delay = if batch["more"], do: 0, else: state.interval_ms
    {:noreply, state |> Map.put(:checkpoint, batch["checkpoint"]) |> schedule(delay)}
  end

  def handle_info(
        {:delivery, reference, {:error, reason}},
        %{in_flight: %{reference: reference}} = state
      )
      when reason in [:rejected, :unavailable] do
    {:noreply, state |> finish_delivery() |> schedule(state.retry_ms)}
  end

  def handle_info(
        {:delivery_timeout, reference},
        %{in_flight: %{reference: reference} = delivery} = state
      ) do
    Process.exit(delivery.pid, :kill)
    Process.demonitor(delivery.monitor, [:flush])
    {:noreply, state |> Map.put(:in_flight, nil) |> schedule(state.retry_ms)}
  end

  def handle_info(
        {:DOWN, monitor, :process, _pid, _reason},
        %{in_flight: %{monitor: monitor}} = state
      ) do
    _ = Process.cancel_timer(state.in_flight.timeout)
    {:noreply, state |> Map.put(:in_flight, nil) |> schedule(state.retry_ms)}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp export(state) do
    case OperationalHistory.export_batch(state.collector,
           checkpoint: state.checkpoint,
           limit: state.batch_size
         ) do
      {:ok, batch} -> maybe_deliver(state, batch)
      {:error, _} -> schedule(state, state.retry_ms)
    end
  end

  defp maybe_deliver(state, batch) do
    if batch["samples"] == [] and batch["continuity"] in ["snapshot", "continuous"] do
      state
      |> Map.put(:checkpoint, batch["checkpoint"])
      |> schedule(state.interval_ms)
    else
      deliver(state, batch)
    end
  end

  defp deliver(state, batch) do
    parent = self()
    reference = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        send(parent, {:delivery, reference, call_adapter(state.adapter, state.context, batch)})
      end)

    timeout = Process.send_after(self(), {:delivery_timeout, reference}, state.timeout_ms)

    Map.put(state, :in_flight, %{
      reference: reference,
      pid: pid,
      monitor: monitor,
      timeout: timeout,
      batch: batch
    })
  end

  defp call_adapter(adapter, context, batch) do
    case adapter.deliver(context, batch) do
      :ok -> :ok
      {:error, reason} when reason in [:rejected, :unavailable] -> {:error, reason}
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp finish_delivery(state) do
    _ = Process.cancel_timer(state.in_flight.timeout)
    Process.demonitor(state.in_flight.monitor, [:flush])
    Map.put(state, :in_flight, nil)
  end

  defp schedule(state, delay) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :export, delay)}
  end

  defp config(options) do
    if valid_options?(options) do
      {adapter, context} = Keyword.fetch!(options, :adapter)

      config = %State{
        collector: Keyword.fetch!(options, :collector),
        adapter: adapter,
        context: context,
        interval_ms: Keyword.get(options, :interval_ms, @default_interval_ms),
        retry_ms: Keyword.get(options, :retry_ms, @default_retry_ms),
        timeout_ms: Keyword.get(options, :timeout_ms, @default_timeout_ms),
        batch_size: Keyword.get(options, :batch_size, @default_batch_size)
      }

      if valid_config?(config), do: {:ok, config}, else: {:error, :invalid_options}
    else
      {:error, :invalid_options}
    end
  end

  defp valid_options?(options),
    do:
      Keyword.keyword?(options) and length(options) == map_size(Map.new(options)) and
        Enum.sort(Keyword.keys(options)) --
          [:adapter, :batch_size, :collector, :interval_ms, :retry_ms, :timeout_ms] == [] and
        Keyword.has_key?(options, :collector) and
        match?({module, _context} when is_atom(module), Keyword.get(options, :adapter))

  defp valid_config?(config),
    do:
      is_pid(config.collector) and is_atom(config.adapter) and
        function_exported?(config.adapter, :deliver, 2) and
        valid_delay?(config.interval_ms, 60_000) and valid_delay?(config.retry_ms, 60_000) and
        valid_delay?(config.timeout_ms, 30_000) and is_integer(config.batch_size) and
        config.batch_size in 1..1_000

  defp valid_delay?(value, maximum), do: is_integer(value) and value in 1..maximum
end
