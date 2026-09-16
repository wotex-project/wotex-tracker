defmodule Wotex.Tracker.Service.OperationalHistoryTest do
  use ExUnit.Case, async: false

  import Wotex.Tracker.Service.Fixtures

  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.HTTP.Server

  alias Wotex.Tracker.Service.{
    ForwardItem,
    Identifier,
    OperationalHistory,
    OperationalTelemetry,
    Store
  }

  test "the event vocabulary documents units and closed low-cardinality metadata" do
    assert [request, query, ingest, store, queue, publication, resource] =
             OperationalTelemetry.contracts()

    assert request.event == [:wotex, :tracker, :service, :request, :stop]
    assert request.measurements == %{duration_us: :microsecond}

    assert request.metadata.outcome ==
             ~w(ok dropped rejected conflict overloaded deadline unavailable unknown)a

    assert query.event == [:wotex, :tracker, :service, :query, :stop]
    assert query.measurements == %{duration_us: :microsecond, scanned_rows: :row}
    assert query.metadata.aggregation == ~w(count min max mean last)a
    assert ingest.metadata.stage == [:admission, :decode]
    assert store.metadata.operation == [:mutation, :rule_state, :rule_event]

    assert queue.measurements == %{
             duration_us: :microsecond,
             depth_items: :count,
             depth_bytes: :byte,
             affected_items: :count,
             dropped_items: :count
           }

    assert publication.metadata.operation == [:lookup, :latest, :confirm]

    assert resource.metadata == %{
             resource: [:store],
             operation: [:readiness, :checkpoint, :backup],
             outcome: request.metadata.outcome
           }
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

  test "ingest, commit, queue, publication and resource boundaries emit bounded outcomes" do
    context = service()

    collector =
      start_supervised!(
        Supervisor.child_spec(
          {OperationalHistory, max_samples: 32, clock: fn -> context.now end},
          id: make_ref()
        )
      )

    assert {:ok, _} =
             Service.submit(
               context.service,
               context.admin,
               context.scope,
               Identifier.uuid(),
               import_request(),
               context.now
             )

    assert {:ok, _} = Store.readiness(context.store)

    assert {:error, :not_found} =
             Store.latest_publication(context.store, context.scope, "missing-thing")

    first = forward_item("telemetry-first")
    dropped = forward_item("telemetry-dropped", :lossy)
    {queue_store, _} = store(forward_max_items: 1)
    assert {:ok, _} = Store.enqueue_forward(queue_store, first)
    assert {:ok, %{"disposition" => "dropped"}} = Store.enqueue_forward(queue_store, dropped)

    eventually(fn ->
      Enum.all?(~w(ingest.stop store.stop queue.stop publication.stop resource.stop), fn event ->
        match?(
          {:ok, %{"samples" => [_ | _]}},
          OperationalHistory.snapshot(collector, event: event)
        )
      end)
    end)

    assert {:ok, %{"samples" => ingest_samples}} =
             OperationalHistory.snapshot(collector, event: "ingest.stop")

    assert Enum.map(ingest_samples, & &1["metadata"]) == [
             %{"stage" => "admission", "outcome" => "ok"},
             %{"stage" => "decode", "outcome" => "ok"}
           ]

    assert {:ok, %{"samples" => queue_samples}} =
             OperationalHistory.snapshot(collector, event: "queue.stop")

    assert %{
             "measurements" => %{
               "depth_items" => 1,
               "affected_items" => 1,
               "dropped_items" => 1
             },
             "metadata" => %{"operation" => "enqueue", "outcome" => "dropped"}
           } = List.last(queue_samples)

    for event <- ~w(ingest.stop store.stop queue.stop publication.stop resource.stop),
        {:ok, %{"samples" => samples}} = OperationalHistory.snapshot(collector, event: event),
        sample <- samples do
      refute Map.has_key?(sample["metadata"], "scope")
      refute Map.has_key?(sample["metadata"], "id")
    end
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

  defp forward_item(id, source \\ :reliable) do
    {:ok, item} =
      ForwardItem.new(%{
        scope: "workshop",
        id: id,
        candidate_id: "cellular",
        bearer: "lte-m",
        application_protocol: "fixture-protocol",
        payload: %{"temperature" => 24.3},
        source: source,
        admitted_at: 1_700_000_000_000,
        required_acknowledgement: :durable_admission
      })

    item
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
