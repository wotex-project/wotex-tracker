defmodule Wotex.Tracker.Service.RecoveryTest do
  @moduledoc false

  use ExUnit.Case, async: true
  import Wotex.Tracker.Service.Fixtures
  import ExUnit.CaptureLog
  alias Wotex.Tracker.Service.Store

  for phase <- [:before_commit, :stale_cleanup] do
    test "#{phase} failure rolls back every part of admission" do
      phase = unquote(phase)

      {store, directory} =
        store(fault: fn current -> if current == phase, do: :abort, else: :ok end)

      assert {:error, :injected_failure} = Store.mutate(store, update())
      GenServer.stop(store.pid)
      {reopened, _} = store(directory: directory)

      assert {:error, :not_found} =
               Store.operation(reopened, "workshop", "operator", "operation-1", 0)

      assert {:ok, %{"generation" => "0", "items" => []}} = Store.snapshot(reopened, query())
      assert {:ok, %{"items" => []}} = Store.snapshot(reopened, query(%{kind: "observations"}))
      assert {:ok, %{"items" => []}} = Store.events(reopened, replay())
      assert {:ok, _} = Store.mutate(reopened, update())
    end
  end

  for phase <- [:before_commit, :after_commit] do
    test "#{phase} crash returns unknown; restart resolves the operation without duplicate effects" do
      phase = unquote(phase)

      {store, directory} =
        store(fault: fn current -> if current == phase, do: :crash, else: :ok end)

      log = capture_log(fn -> assert {:error, :unknown} = Store.mutate(store, update()) end)
      refute log =~ "private-hardware"
      refute log =~ "private-receiver"
      {reopened, _} = store(directory: directory)

      assert_recovered_operation(phase, reopened)

      assert {:ok, %{"generation" => "1"}} = Store.mutate(reopened, update())
      assert {:ok, %{"items" => [_]}} = Store.events(reopened, replay())
    end
  end

  test "post-commit lost acknowledgement never reports a pre-commit failure" do
    {store, _} = store(fault: fn phase -> if phase == :after_commit, do: :abort, else: :ok end)
    assert {:error, :unknown} = Store.mutate(store, update())

    assert {:ok, %{"outcome" => "committed", "generation" => "1"}} =
             Store.operation(store, "workshop", "operator", "operation-1", 0)
  end

  test "timeout retains its reservation until completion; a late reply does not pollute caller mailbox" do
    {store, _} = store(timeout: 30, fault: blocking_fault(self()))
    assert {:error, :unknown} = Store.mutate(store, update())
    # The 30 ms caller deadline can expire before the writer reaches its fault.
    assert_receive {:blocked, writer}
    assert :ets.info(store.slots, :size) == 1
    send(writer, :continue)
    eventually(fn -> :ets.info(store.slots, :size) == 0 end)

    assert {:ok, %{"generation" => "1"}} =
             Store.operation(store, "workshop", "operator", "operation-1", 0)

    refute_received {_reference, {:ok, _}}
  end

  test "dead callers cannot release queued capacity early or lose committed work" do
    {store, _} = store(fault: blocking_fault(self()))
    caller = spawn(fn -> Store.mutate(store, update()) end)
    assert_receive {:blocked, writer}
    Process.exit(caller, :kill)
    assert :ets.info(store.slots, :size) == 1
    send(writer, :continue)
    eventually(fn -> :ets.info(store.slots, :size) == 0 end)
    assert {:ok, _} = Store.operation(store, "workshop", "operator", "operation-1", 0)
  end

  test "32 reservations bound queued mutations and overload rejects before enqueue" do
    {store, _} = store(fault: blocking_fault(self()))
    calls = for _ <- 1..32, do: Task.async(fn -> Store.mutate(store, update()) end)
    assert_receive {:blocked, writer}
    eventually(fn -> :ets.info(store.slots, :size) == 32 end)
    assert {:error, :overloaded} = Store.mutate(store, update())
    send(writer, :continue)
    assert Enum.all?(Task.await_many(calls), &match?({:ok, %{"generation" => "1"}}, &1))
    eventually(fn -> :ets.info(store.slots, :size) == 0 end)
    GenServer.stop(store.pid)
    assert {:error, :storage_unavailable} = Store.readiness(store)
  end

  defp blocking_fault(receiver) do
    fn phase ->
      if phase == :before_commit and not Process.get(:blocked_once, false) do
        Process.put(:blocked_once, true)
        send(receiver, {:blocked, self()})

        receive do
          :continue -> :ok
        after
          4000 -> :crash
        end
      else
        :ok
      end
    end
  end

  defp assert_recovered_operation(:before_commit, store) do
    assert {:error, :not_found} = Store.operation(store, "workshop", "operator", "operation-1", 0)
  end

  defp assert_recovered_operation(:after_commit, store) do
    assert {:ok, %{"outcome" => "committed"}} =
             Store.operation(store, "workshop", "operator", "operation-1", 0)
  end

  defp eventually(check, attempts \\ 100)
  defp eventually(check, 0), do: assert(check.())

  defp eventually(check, attempts) do
    unless check.() do
      Process.sleep(5)
      eventually(check, attempts - 1)
    end
  end
end
