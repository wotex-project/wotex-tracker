defmodule Wotex.Tracker.Service.HTTP.SSEGuard do
  @moduledoc false

  # Monitors before connect. It receives only a socket, never a credential or
  # callback closure, and closes pending I/O when either participant disappears.
  def start(owner, deadline) do
    caller = self()
    reference = make_ref()
    {pid, monitor} = spawn_monitor(fn -> init(caller, owner, reference, deadline) end)
    handle = {pid, monitor, reference}

    receive do
      {^reference, :ready} -> {:ok, handle}
      {:DOWN, ^monitor, :process, ^pid, _} -> {:error, :request_failed}
    after
      1000 ->
        stop(handle)
        {:error, :timeout}
    end
  end

  def attach({pid, monitor, reference}, socket) do
    send(pid, {reference, :socket, socket})

    receive do
      {^reference, :attached} -> :ok
      {:DOWN, ^monitor, :process, ^pid, _} -> {:error, :request_failed}
    after
      1000 -> {:error, :timeout}
    end
  end

  def stop({pid, monitor, reference}) do
    if Process.alive?(pid) do
      send(pid, {reference, :stop})

      receive do
        {:DOWN, ^monitor, :process, ^pid, _} -> :ok
      after
        1000 -> Process.exit(pid, :kill)
      end
    end

    Process.demonitor(monitor, [:flush])
    :ok
  end

  defp init(caller, owner, reference, deadline) do
    caller_monitor = Process.monitor(caller)
    owner_monitor = Process.monitor(owner)

    if Process.alive?(owner) do
      send(caller, {reference, :ready})
      watch(caller, {caller_monitor, owner_monitor}, reference, deadline, nil)
    end
  end

  defp watch(caller, {caller_monitor, owner_monitor} = monitors, reference, deadline, socket) do
    receive do
      {^reference, :socket, acquired} ->
        send(caller, {reference, :attached})
        watch(caller, monitors, reference, deadline, acquired)

      {^reference, :stop} ->
        :ok

      {:DOWN, monitor, :process, _, _} when monitor in [caller_monitor, owner_monitor] ->
        close(socket)
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> close(socket)
    end
  end

  defp close(nil), do: :ok
  defp close(socket), do: :gen_tcp.close(socket)
end
