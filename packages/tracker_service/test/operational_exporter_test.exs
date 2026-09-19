defmodule Wotex.Tracker.Service.OperationalExporterTest do
  use ExUnit.Case, async: false

  alias Wotex.Tracker.Service.{OperationalExporter, OperationalHistory, OperationalTelemetry}

  defmodule Peer do
    @behaviour Wotex.Tracker.Service.OperationalExportAdapter

    @impl true
    def deliver(%{control: control, owner: owner}, batch) do
      behavior =
        Agent.get_and_update(control, fn
          [next | rest] -> {next, rest}
          [] -> {:ok, []}
        end)

      send(owner, {:delivery_attempt, batch, behavior})

      case behavior do
        :ok -> :ok
        :unavailable -> {:error, :unavailable}
        :rejected -> {:error, :rejected}
        {:sleep, milliseconds} -> Process.sleep(milliseconds)
        :raise -> raise "synthetic exporter failure"
      end
    end
  end

  test "failed batches retry unchanged and checkpoints advance only after acknowledgement" do
    collector = start_supervised!({OperationalHistory, []})

    for _ <- 1..3, do: OperationalTelemetry.request(:health, 200, System.monotonic_time())

    eventually(fn ->
      match?({:ok, %{"samples" => [_, _, _]}}, OperationalHistory.snapshot(collector))
    end)

    {:ok, control} = Agent.start_link(fn -> [:unavailable, :rejected, :ok, :ok, :ok] end)

    exporter =
      start_supervised!(
        {OperationalExporter,
         collector: collector,
         adapter: {Peer, %{owner: self(), control: control}},
         batch_size: 2,
         interval_ms: 20,
         retry_ms: 5,
         timeout_ms: 50}
      )

    assert_receive {:delivery_attempt, first, :unavailable}, 200
    assert Enum.map(first["samples"], & &1["sequence"]) == [1, 2]

    assert_receive {:delivery_attempt, rejected, :rejected}, 200
    assert retry_identity(rejected) == retry_identity(first)

    assert_receive {:delivery_attempt, retried, :ok}, 200
    assert retry_identity(retried) == retry_identity(first)

    assert_receive {:delivery_attempt, second, :ok}, 200
    assert Enum.map(second["samples"], & &1["sequence"]) == [3]
    assert second["continuity"] == "continuous"

    eventually(fn ->
      match?(
        {:ok, %{"checkpoint" => %{"after" => 3}, "delivering" => false}},
        OperationalExporter.status(exporter)
      )
    end)

    OperationalTelemetry.request(:health, 200, System.monotonic_time())
    assert_receive {:delivery_attempt, third, :ok}, 200
    assert Enum.map(third["samples"], & &1["sequence"]) == [4]
    refute inspect(:sys.get_state(exporter)) =~ inspect(control)
  end

  test "a timed-out or crashing adapter cannot block the collector" do
    collector = start_supervised!({OperationalHistory, []})
    OperationalTelemetry.request(:health, 200, System.monotonic_time())

    eventually(fn ->
      match?({:ok, %{"samples" => [_]}}, OperationalHistory.snapshot(collector))
    end)

    {:ok, control} = Agent.start_link(fn -> [{:sleep, 100}, :raise, :ok] end)

    exporter =
      start_supervised!(
        {OperationalExporter,
         collector: collector,
         adapter: {Peer, %{owner: self(), control: control}},
         interval_ms: 20,
         retry_ms: 5,
         timeout_ms: 10}
      )

    assert_receive {:delivery_attempt, first, {:sleep, 100}}, 200
    assert_receive {:delivery_attempt, crashed, :raise}, 200
    assert retry_identity(crashed) == retry_identity(first)
    assert_receive {:delivery_attempt, retried, :ok}, 200
    assert retry_identity(retried) == retry_identity(first)
    assert Process.alive?(exporter)
    assert {:ok, %{"samples" => [_]}} = OperationalHistory.snapshot(collector)
  end

  test "configuration is closed and requires an adapter implementation" do
    collector = start_supervised!({OperationalHistory, []})

    for options <- [
          [],
          [collector: collector, adapter: :invalid],
          [collector: collector, adapter: {String, nil}],
          [collector: collector, adapter: {Peer, nil}, batch_size: 0],
          [collector: collector, adapter: {Peer, nil}, interval_ms: 0],
          [collector: collector, adapter: {Peer, nil}, extra: true],
          [collector: collector, collector: collector, adapter: {Peer, nil}]
        ] do
      assert {:error, :invalid_options} = OperationalExporter.start_link(options)
    end
  end

  defp eventually(check, attempts \\ 100)
  defp eventually(check, 0), do: assert(check.())

  defp eventually(check, attempts) do
    unless check.() do
      Process.sleep(5)
      eventually(check, attempts - 1)
    end
  end

  defp retry_identity(batch),
    do: Map.take(batch, ~w(schema epoch continuity samples checkpoint))
end
