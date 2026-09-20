defmodule Wotex.Tracker.Service.PassiveScanner do
  @moduledoc """
  Explicit bounded owner for one passive BLE adapter and ingress.

  Adapter initialization and each pull run in monitored workers with finite
  deadlines. At most one capture is in flight, providing backpressure without
  an unbounded advertisement mailbox. Loading Tracker starts no scanner.
  """

  use GenServer

  alias Wotex.Tracker.Service.{PassiveAdvertisement, PassiveIngress}

  @maximum_timeout 30_000
  @maximum_interval 60_000

  @doc "Starts one explicitly selected passive scanner."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) when is_list(options) do
    with {:ok, state, server_options} <- options(options),
         do: GenServer.start_link(__MODULE__, state, server_options)
  end

  def start_link(_), do: {:error, :invalid_configuration}

  @doc "Reports only bounded lifecycle counters; adapter state remains private."
  @spec status(GenServer.server()) :: map()
  def status(server), do: GenServer.call(server, :status)

  @impl true
  def init(state) do
    Process.flag(:trap_exit, true)

    case isolated(state.timeout_ms, fn -> state.module.init(state.context) end) do
      {:ok, {:ok, adapter_state}} ->
        send(self(), :poll)
        {:ok, %{state | adapter_state: adapter_state, lifecycle: :running}}

      _ ->
        {:stop, :adapter_unavailable}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       lifecycle: state.lifecycle,
       accepted: state.accepted,
       duplicate: state.duplicate,
       rejected: state.rejected,
       unknown: state.unknown
     }, state}
  end

  @impl true
  def handle_info(:poll, %{lifecycle: :running} = state) do
    result = isolated(state.timeout_ms, fn -> state.module.next(state.adapter_state) end)

    case result do
      {:ok, {:ok, advertisement, adapter_state}} ->
        state = %{state | adapter_state: adapter_state} |> submit(advertisement)
        schedule(state.interval_ms)
        {:noreply, state}

      {:ok, {:idle, adapter_state}} ->
        schedule(state.interval_ms)
        {:noreply, %{state | adapter_state: adapter_state}}

      {:ok, {:stop, adapter_state}} ->
        {:noreply, %{state | adapter_state: adapter_state, lifecycle: :stopped}}

      {:ok, {:error, _reason, adapter_state}} ->
        schedule(state.interval_ms)
        {:noreply, %{state | adapter_state: adapter_state, rejected: state.rejected + 1}}

      _ ->
        {:stop, :adapter_unavailable, state}
    end
  end

  def handle_info(:poll, state), do: {:noreply, state}
  def handle_info({:EXIT, _, _}, state), do: {:noreply, state}

  @impl true
  def terminate(reason, %{module: module, adapter_state: adapter_state}) do
    if function_exported?(module, :terminate, 2) do
      _ = isolated(1_000, fn -> module.terminate(reason, adapter_state) end)
    end

    :ok
  end

  def terminate(_, _), do: :ok

  defp options(options) do
    allowed = [:adapter, :ingress, :interval_ms, :timeout_ms, :name]
    required = [:adapter, :ingress]

    if Keyword.keyword?(options) and
         length(options) == length(Enum.uniq(Keyword.keys(options))) and
         Enum.all?(Keyword.keys(options), &(&1 in allowed)) and
         Enum.all?(required, &Keyword.has_key?(options, &1)) do
      {module, context} = Keyword.fetch!(options, :adapter)

      state = %{
        module: module,
        context: context,
        ingress: Keyword.fetch!(options, :ingress),
        interval_ms: Keyword.get(options, :interval_ms, 100),
        timeout_ms: Keyword.get(options, :timeout_ms, 5_000),
        adapter_state: nil,
        lifecycle: :starting,
        accepted: 0,
        duplicate: 0,
        rejected: 0,
        unknown: 0
      }

      if state?(state),
        do: {:ok, state, Keyword.take(options, [:name])},
        else: {:error, :invalid_configuration}
    else
      {:error, :invalid_configuration}
    end
  rescue
    _ -> {:error, :invalid_configuration}
  end

  defp state?(state) do
    is_atom(state.module) and Code.ensure_loaded?(state.module) and
      function_exported?(state.module, :init, 1) and function_exported?(state.module, :next, 1) and
      server?(state.ingress) and is_integer(state.interval_ms) and
      state.interval_ms in 0..@maximum_interval and is_integer(state.timeout_ms) and
      state.timeout_ms in 1..@maximum_timeout
  end

  defp server?(server) when is_pid(server), do: Process.alive?(server)
  defp server?(server) when is_atom(server), do: server not in [nil, false, true]
  defp server?({:global, _}), do: true
  defp server?({:via, module, _}), do: is_atom(module)
  defp server?(_), do: false

  defp submit(state, advertisement) do
    result =
      with {:ok, advertisement} <- PassiveAdvertisement.validate(advertisement),
           {:ok, receipt} <- PassiveIngress.submit(state.ingress, advertisement, state.timeout_ms) do
        receipt.disposition
      else
        _ -> :rejected
      end

    Map.update!(state, result, &(&1 + 1))
  rescue
    _ -> Map.update!(state, :unknown, &(&1 + 1))
  catch
    :exit, _ -> Map.update!(state, :unknown, &(&1 + 1))
  end

  defp schedule(interval), do: Process.send_after(self(), :poll, interval)

  defp isolated(timeout, function) do
    owner = self()
    reference = make_ref()

    {worker, monitor} =
      spawn_monitor(fn ->
        result =
          try do
            {:ok, function.()}
          rescue
            _ -> {:error, :unavailable}
          catch
            _, _ -> {:error, :unavailable}
          end

        send(owner, {reference, result})
      end)

    receive do
      {^reference, result} ->
        Process.demonitor(monitor, [:flush])
        result
    after
      timeout ->
        Process.exit(worker, :kill)
        Process.demonitor(monitor, [:flush])
        {:error, :timeout}
    end
  end
end
