defmodule Wotex.Tracker.Service.OperationalHistoryTest do
  use ExUnit.Case, async: false

  import Wotex.Tracker.Service.Fixtures

  alias Wotex.Tracker.Service.HTTP.Server
  alias Wotex.Tracker.Service.{OperationalHistory, OperationalTelemetry}

  test "the event vocabulary documents units and closed low-cardinality metadata" do
    assert [request, query] = OperationalTelemetry.contracts()
    assert request.event == [:wotex, :tracker, :service, :request, :stop]
    assert request.measurements == %{duration_us: :microsecond}

    assert request.metadata.outcome ==
             ~w(ok rejected conflict overloaded deadline unavailable unknown)a

    assert query.event == [:wotex, :tracker, :service, :query, :stop]
    assert query.measurements == %{duration_us: :microsecond, scanned_rows: :row}
    assert query.metadata.aggregation == ~w(count min max mean last)a
  end

  test "bounded volatile samples expire and malformed external events are ignored" do
    clock = :atomics.new(1, [])
    :atomics.put(clock, 1, 1_000)

    collector =
      start_supervised!(
        Supervisor.child_spec(
          {OperationalHistory,
           max_samples: 3, retention_ms: 10, clock: fn -> :atomics.get(clock, 1) end},
          id: make_ref()
        )
      )

    for _ <- 1..4,
        do: OperationalTelemetry.request(:health, 200, System.monotonic_time())

    eventually(fn ->
      match?({:ok, %{"samples" => [_, _, _]}}, OperationalHistory.snapshot(collector))
    end)

    {:ok, snapshot} = OperationalHistory.snapshot(collector, event: "request.stop", limit: 2)
    assert snapshot["volatile"]
    assert byte_size(snapshot["epoch"]) == 16
    assert length(snapshot["samples"]) == 2

    Enum.each(snapshot["samples"], fn sample ->
      assert sample["event"] == "request.stop"
      assert sample["metadata"] == %{"operation" => "health", "outcome" => "ok"}
      assert is_integer(sample["measurements"]["duration_us"])
      refute Map.has_key?(sample["metadata"], "scope")
    end)

    OperationalTelemetry.query(
      :mean,
      {:ok, %{"scanned_rows" => 17}},
      System.monotonic_time()
    )

    eventually(fn ->
      match?(
        {:ok, %{"samples" => [%{"measurements" => %{"scanned_rows" => 17}}]}},
        OperationalHistory.snapshot(collector, event: "query.stop")
      )
    end)

    [query_event | _] = Enum.reverse(OperationalTelemetry.event_names())
    :telemetry.execute(query_event, %{duration_us: -1}, %{private: "payload"})
    Process.sleep(10)

    assert {:ok, %{"samples" => [%{"metadata" => metadata}]}} =
             OperationalHistory.snapshot(collector, event: "query.stop")

    assert metadata == %{"aggregation" => "mean", "outcome" => "ok"}

    :atomics.put(clock, 1, 1_011)
    assert {:ok, %{"samples" => []}} = OperationalHistory.snapshot(collector)
    assert {:error, :invalid_query} = OperationalHistory.snapshot(collector, event: "unknown")
  end

  test "collector restart clears samples and changes the epoch" do
    first =
      start_supervised!(
        Supervisor.child_spec({OperationalHistory, []}, id: make_ref(), restart: :temporary)
      )

    OperationalTelemetry.request(:health, 200, System.monotonic_time())
    eventually(fn -> match?({:ok, %{"samples" => [_]}}, OperationalHistory.snapshot(first)) end)
    {:ok, %{"epoch" => epoch}} = OperationalHistory.snapshot(first)
    GenServer.stop(first)

    second =
      start_supervised!(
        Supervisor.child_spec({OperationalHistory, []}, id: make_ref(), restart: :temporary)
      )

    assert {:ok, %{"epoch" => changed, "samples" => []}} = OperationalHistory.snapshot(second)
    refute changed == epoch
  end

  test "the explicit HTTP host owns a collector and records request outcomes" do
    Application.ensure_all_started(:inets)
    context = service()
    server = start_supervised!({Server, server_options(context)})
    {:ok, {_, port}} = Server.listener_info(server)
    url = String.to_charlist("http://127.0.0.1:#{port}/health/live")
    {:ok, {{_, 200, _}, _, _}} = :httpc.request(:get, {url, []}, [], body_format: :binary)

    eventually(fn ->
      case Server.operational_history(server, event: "request.stop") do
        {:ok, %{"samples" => samples}} ->
          Enum.any?(samples, &(&1["metadata"] == %{"operation" => "health", "outcome" => "ok"}))

        _ ->
          false
      end
    end)
  end

  defp server_options(context),
    do: [
      directory: context.directory,
      credentials: context.credentials,
      ip: {127, 0, 0, 1},
      port: 0,
      public_origin: :listener,
      exposure: :loopback,
      clock: fn -> context.now end,
      poll_interval: 25,
      operational_history: [max_samples: 16, retention_ms: 1_000]
    ]

  defp eventually(check, attempts \\ 100)
  defp eventually(check, 0), do: assert(check.())

  defp eventually(check, attempts) do
    unless check.() do
      Process.sleep(5)
      eventually(check, attempts - 1)
    end
  end
end
