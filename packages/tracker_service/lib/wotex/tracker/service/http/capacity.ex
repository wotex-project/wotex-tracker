defmodule Wotex.Tracker.Service.HTTP.Capacity do
  @moduledoc false

  use GenServer

  def start_link(options), do: GenServer.start_link(__MODULE__, options)
  def acquire(pid), do: GenServer.call(pid, :acquire)
  def stream(pid, lease), do: GenServer.call(pid, {:stream, lease})
  def release(pid, lease), do: GenServer.call(pid, {:release, lease})
  def counts(pid), do: GenServer.call(pid, :counts)

  @impl true
  def init(options),
    do: {:ok, %{leases: %{}, options: Map.take(options, [:request_timeout, :stream_lifetime])}}

  @impl true
  def handle_call(:acquire, {owner, _}, state) do
    if count(state, :request) < 32 do
      lease = make_ref()
      entry = entry(owner, :request, lease, state.options)
      {:reply, {:ok, lease}, put_in(state.leases[lease], entry)}
    else
      {:reply, {:error, :overloaded}, state}
    end
  end

  def handle_call({:stream, lease}, {owner, _}, state) do
    case state.leases[lease] do
      %{owner: ^owner, kind: :request} ->
        if count(state, :stream) < 16 do
          state = remove(state, lease)
          {:reply, :ok, put_in(state.leases[lease], entry(owner, :stream, lease, state.options))}
        else
          {:reply, {:error, :overloaded}, state}
        end

      _ ->
        {:reply, {:error, :overloaded}, state}
    end
  end

  def handle_call({:release, lease}, {owner, _}, state) do
    case state.leases[lease] do
      %{owner: ^owner} -> {:reply, :ok, remove(state, lease)}
      _ -> {:reply, :ok, state}
    end
  end

  def handle_call(:counts, _, state),
    do: {:reply, %{requests: count(state, :request), streams: count(state, :stream)}, state}

  @impl true
  def handle_info({:DOWN, monitor, :process, _, _}, state) do
    leases = for {lease, %{monitor: ^monitor}} <- state.leases, do: lease
    {:noreply, Enum.reduce(leases, state, &remove(&2, &1))}
  end

  def handle_info({:expire, lease, stamp}, state) do
    case state.leases[lease] do
      %{stamp: ^stamp, owner: owner} ->
        Process.exit(owner, :kill)
        {:noreply, remove(state, lease)}

      _ ->
        {:noreply, state}
    end
  end

  defp entry(owner, kind, lease, options) do
    stamp = make_ref()
    timeout = if kind == :request, do: options.request_timeout, else: options.stream_lifetime

    %{
      owner: owner,
      kind: kind,
      monitor: Process.monitor(owner),
      stamp: stamp,
      timer: Process.send_after(self(), {:expire, lease, stamp}, timeout)
    }
  end

  defp count(state, kind), do: Enum.count(state.leases, fn {_, entry} -> entry.kind == kind end)

  defp remove(state, lease) do
    {entry, leases} = Map.pop(state.leases, lease)
    Process.cancel_timer(entry.timer)
    Process.demonitor(entry.monitor, [:flush])
    %{state | leases: leases}
  end
end
