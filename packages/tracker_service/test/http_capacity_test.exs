defmodule Wotex.Tracker.HTTPCapacityTest do
  @moduledoc false
  use ExUnit.Case, async: true
  alias Wotex.Tracker.Service.HTTP.Capacity

  test "32 requests and 16 streams have separate reservations released on owner death" do
    capacity = start_supervised!({Capacity, %{request_timeout: 5000, stream_lifetime: 5000}})
    owners = for _ <- 1..32, do: owner(capacity)
    assert %{requests: 32, streams: 0} = Capacity.counts(capacity)
    assert {:error, :overloaded} = Capacity.acquire(capacity)
    [{first, first_lease} | _] = owners
    assert {:error, :overloaded} = Capacity.stream(capacity, first_lease)
    assert :ok = Capacity.release(capacity, first_lease)
    assert %{requests: 32} = Capacity.counts(capacity)

    Enum.each(Enum.take(owners, 16), fn {pid, _} ->
      send(pid, :stream)
      assert_receive {^pid, :stream, :ok}
    end)

    {seventeenth, _} = Enum.at(owners, 16)
    send(seventeenth, :stream)
    assert_receive {^seventeenth, :stream, {:error, :overloaded}}
    assert %{requests: 16, streams: 16} = Capacity.counts(capacity)
    Process.exit(first, :kill)
    eventually(fn -> Capacity.counts(capacity) == %{requests: 16, streams: 15} end)
    for {pid, _} <- tl(owners), do: send(pid, :stop)
    eventually(fn -> Capacity.counts(capacity) == %{requests: 0, streams: 0} end)
    assert :ok = Capacity.release(capacity, make_ref())
  end

  test "hard deadlines close the owner and request-to-stream transfer cancels the old deadline" do
    capacity = start_supervised!({Capacity, %{request_timeout: 50, stream_lifetime: 250}})
    {request, _} = owner(capacity)
    monitor = Process.monitor(request)
    assert_receive {:DOWN, ^monitor, :process, ^request, :killed}, 1000
    assert %{requests: 0, streams: 0} = Capacity.counts(capacity)
    {stream, _} = owner(capacity)
    monitor = Process.monitor(stream)
    send(stream, :stream)
    assert_receive {^stream, :stream, :ok}
    refute_receive {:DOWN, ^monitor, _, _, _}, 100
    assert %{requests: 0, streams: 1} = Capacity.counts(capacity)
    assert_receive {:DOWN, ^monitor, :process, ^stream, :killed}, 1000
    assert %{requests: 0, streams: 0} = Capacity.counts(capacity)
    send(capacity, {:expire, make_ref(), make_ref()})
    assert %{requests: 0, streams: 0} = Capacity.counts(capacity)
  end

  defp owner(capacity) do
    parent = self()

    pid =
      spawn(fn ->
        {:ok, lease} = Capacity.acquire(capacity)
        send(parent, {self(), lease})
        await(capacity, lease, parent)
      end)

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    assert_receive {^pid, lease}
    {pid, lease}
  end

  defp await(capacity, lease, parent) do
    receive do
      :stream ->
        send(parent, {self(), :stream, Capacity.stream(capacity, lease)})
        await(capacity, lease, parent)

      :stop ->
        Capacity.release(capacity, lease)
    end
  end

  defp eventually(check, tries \\ 100)
  defp eventually(check, 0), do: assert(check.())

  defp eventually(check, tries) do
    unless check.() do
      Process.sleep(5)
      eventually(check, tries - 1)
    end
  end
end
