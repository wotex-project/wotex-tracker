defmodule Wotex.Tracker.Service.StoreCall do
  @moduledoc false

  def run(store, message) do
    deadline = System.monotonic_time(:millisecond) + store.timeout
    recipient = Process.alias()
    {pid, monitor} = spawn_monitor(fn -> worker(store, message, recipient) end)

    try do
      receive do
        {^recipient, result} -> await_cleanup(pid, monitor, result, deadline)
        {:DOWN, ^monitor, :process, ^pid, _} -> {:error, :unknown}
      after
        store.timeout -> {:error, :unknown}
      end
    after
      Process.unalias(recipient)
      Process.demonitor(monitor, [:flush])
    end
  end

  defp await_cleanup(pid, monitor, result, deadline) do
    receive do
      {:DOWN, ^monitor, :process, ^pid, _} -> result
    after
      max(0, deadline - System.monotonic_time(:millisecond)) -> result
    end
  end

  defp worker(store, message, recipient) do
    case reserve(store.slots) do
      {:ok, slot} ->
        try do
          send(recipient, {recipient, GenServer.call(store.pid, message, :infinity)})
        catch
          :exit, _ -> send(recipient, {recipient, {:error, :unknown}})
        after
          release(store.slots, slot)
        end

      error ->
        send(recipient, {recipient, error})
    end
  end

  defp reserve(table) do
    case Enum.find(1..32, &:ets.insert_new(table, {&1, self()})) do
      nil -> {:error, :overloaded}
      slot -> {:ok, slot}
    end
  rescue
    ArgumentError -> {:error, :storage_unavailable}
  end

  defp release(table, slot) do
    :ets.delete(table, slot)
  rescue
    ArgumentError -> :ok
  end
end
