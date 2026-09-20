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
    assert [
             request,
             query,
             ingest,
             store,
             queue,
             publication,
             resource,
             runtime,
             render,
             connection,
             native
           ] =
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

    assert runtime.event == [:wotex, :tracker, :service, :runtime, :sample]

    assert runtime.measurements == %{
             beam_memory_bytes: :byte,
             process_count: :count,
             port_count: :count
           }

    assert runtime.metadata == %{runtime: [:beam]}
    assert render.event == [:wotex, :tracker, :browser, :render, :stop]
    assert render.measurements == %{duration_us: :microsecond}
    assert render.metadata == %{surface: [:browser], outcome: [:ok, :unavailable]}

    assert connection.event == [:wotex, :tracker, :browser, :connection, :stop]
    assert connection.measurements == %{duration_us: :microsecond}

    assert connection.metadata == %{
             surface: [:browser],
             kind: [:reconnect],
             outcome: [:ok, :unavailable]
           }

    assert native.event == [:wotex, :tracker, :native, :resource, :sample]

    assert native.measurements == %{
             system_available_memory_bytes: :byte,
             process_rss_bytes: :byte,
             load_1m_milli: :milli_load
           }

    assert native.metadata == %{surface: [:nerves, :service], source: [:linux_procfs]}
  end

  test "browser render samples keep only closed duration and status" do
    collector = start_supervised!({OperationalHistory, []})
    duration = System.convert_time_unit(2_500, :microsecond, :native)
    :ok = OperationalTelemetry.browser_render(:ok, duration)

    eventually(fn ->
      match?(
        {:ok, %{"samples" => [_]}},
        OperationalHistory.snapshot(collector, event: "render.stop")
      )
    end)

    assert {:ok, %{"samples" => [sample]}} =
             OperationalHistory.snapshot(collector, event: "render.stop")

    assert sample["measurements"] == %{"duration_us" => 2_500}
    assert sample["metadata"] == %{"surface" => "browser", "outcome" => "ok"}

    :telemetry.execute(
      [:wotex, :tracker, :browser, :render, :stop],
      %{duration_us: 1},
      %{surface: :browser, outcome: :ok, asset_id: "private"}
    )

    Process.sleep(10)

    assert {:ok, %{"samples" => [_]}} =
             OperationalHistory.snapshot(collector, event: "render.stop")
  end

  test "browser reconnect samples keep only closed duration, kind and status" do
    collector = start_supervised!({OperationalHistory, []})
    duration = System.convert_time_unit(1_500, :microsecond, :native)
    :ok = OperationalTelemetry.browser_connection(:ok, duration)

    eventually(fn ->
      match?(
        {:ok, %{"samples" => [_]}},
        OperationalHistory.snapshot(collector, event: "connection.stop")
      )
    end)

    assert {:ok, %{"samples" => [sample]}} =
             OperationalHistory.snapshot(collector, event: "connection.stop")

    assert sample["measurements"] == %{"duration_us" => 1_500}

    assert sample["metadata"] == %{
             "surface" => "browser",
             "kind" => "reconnect",
             "outcome" => "ok"
           }

    :telemetry.execute(
      [:wotex, :tracker, :browser, :connection, :stop],
      %{duration_us: 1},
      %{surface: :browser, kind: :reconnect, outcome: :ok, path: "/private"}
    )

    Process.sleep(10)

    assert {:ok, %{"samples" => [_]}} =
             OperationalHistory.snapshot(collector, event: "connection.stop")
  end

  test "native resource samples keep only bounded measurements and closed host labels" do
    collector = start_supervised!({OperationalHistory, []})

    assert :ok =
             OperationalTelemetry.native_resource_sample(:nerves, :linux_procfs, %{
               system_available_memory_bytes: 8_192,
               process_rss_bytes: 4_096,
               load_1m_milli: 125
             })

    assert :ok =
             OperationalTelemetry.native_resource_sample(:service, :linux_procfs, %{
               system_available_memory_bytes: 4_096,
               process_rss_bytes: 2_048,
               load_1m_milli: 75
             })

    assert {:error, :invalid_sample} =
             OperationalTelemetry.native_resource_sample(:nerves, :linux_procfs, %{
               system_available_memory_bytes: 1,
               process_rss_bytes: 1,
               load_1m_milli: 1,
               path: 1
             })

    assert {:error, :invalid_sample} =
             OperationalTelemetry.native_resource_sample(:browser, :linux_procfs, %{})

    eventually(fn ->
      match?(
        {:ok, %{"samples" => [_, _]}},
        OperationalHistory.snapshot(collector, event: "native.sample")
      )
    end)

    assert {:ok, %{"samples" => samples}} =
             OperationalHistory.snapshot(collector, event: "native.sample")

    service_sample = Enum.find(samples, &(&1["metadata"]["surface"] == "service"))
    nerves_sample = Enum.find(samples, &(&1["metadata"]["surface"] == "nerves"))

    assert service_sample["measurements"] == %{
             "system_available_memory_bytes" => 4_096,
             "process_rss_bytes" => 2_048,
             "load_1m_milli" => 75
           }

    assert service_sample["metadata"] == %{
             "surface" => "service",
             "source" => "linux_procfs"
           }

    assert nerves_sample["measurements"] == %{
             "system_available_memory_bytes" => 8_192,
             "process_rss_bytes" => 4_096,
             "load_1m_milli" => 125
           }

    assert nerves_sample["metadata"] == %{
             "surface" => "nerves",
             "source" => "linux_procfs"
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

    query_event = [:wotex, :tracker, :service, :query, :stop]
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

  test "pages pin an epoch and high-water mark and reject expired or altered continuations" do
    clock = :atomics.new(1, [])
    :atomics.put(clock, 1, 1_000)

    collector =
      start_supervised!(
        Supervisor.child_spec(
          {OperationalHistory,
           max_samples: 5, retention_ms: 50, clock: fn -> :atomics.get(clock, 1) end},
          id: make_ref()
        )
      )

    for _ <- 1..3, do: OperationalTelemetry.request(:health, 200, System.monotonic_time())

    eventually(fn ->
      match?({:ok, %{"samples" => [_, _, _]}}, OperationalHistory.snapshot(collector))
    end)

    assert {:ok, %{"samples" => [%{"sequence" => 1}], "through" => 3, "cursor" => first}} =
             OperationalHistory.page(collector, limit: 1)

    OperationalTelemetry.request(:health, 200, System.monotonic_time())

    eventually(fn ->
      match?({:ok, %{"samples" => [_, _, _, _]}}, OperationalHistory.snapshot(collector))
    end)

    assert {:ok, %{"samples" => [%{"sequence" => 2}], "through" => 3, "cursor" => second}} =
             OperationalHistory.page(collector, limit: 1, cursor: first)

    assert {:ok, %{"samples" => [%{"sequence" => 3}], "cursor" => nil}} =
             OperationalHistory.page(collector, limit: 1, cursor: second)

    assert {:error, :invalid_cursor} = OperationalHistory.page(collector, limit: 2, cursor: first)
    assert {:error, :invalid_query} = OperationalHistory.page(collector, limit: 1, limit: 2)
    assert {:error, :invalid_query} = OperationalHistory.page(collector, event: "unknown")
    assert {:error, :invalid_cursor} = OperationalHistory.page(collector, limit: 1, cursor: %{})

    assert {:error, :invalid_cursor} =
             OperationalHistory.page(collector, limit: 1, event: "query.stop", cursor: first)

    assert {:error, :invalid_cursor} =
             OperationalHistory.page(collector, limit: 1, cursor: %{first | "through" => 9})

    replacement =
      start_supervised!(
        Supervisor.child_spec({OperationalHistory, clock: fn -> :atomics.get(clock, 1) end},
          id: make_ref()
        )
      )

    assert {:error, :invalid_cursor} =
             OperationalHistory.page(replacement, limit: 1, cursor: first)

    assert {:ok, %{"samples" => [], "cursor" => nil}} = OperationalHistory.page(replacement)

    :atomics.put(clock, 1, 1_051)
    assert {:error, :cursor_expired} = OperationalHistory.page(collector, limit: 1, cursor: first)
    GenServer.stop(replacement)
    assert {:error, :unavailable} = OperationalHistory.page(replacement)
  end

  test "window pages pin elapsed bounds and disclose graph projection limits" do
    clock = :atomics.new(1, [])
    :atomics.put(clock, 1, 1_000)

    collector =
      start_supervised!(
        Supervisor.child_spec(
          {OperationalHistory,
           max_samples: 1_100, retention_ms: 500, clock: fn -> :atomics.get(clock, 1) end},
          id: make_ref()
        )
      )

    record = fn time, event ->
      :atomics.put(clock, 1, time)

      case event do
        :request ->
          OperationalTelemetry.request(:health, 200, System.monotonic_time())

        :query ->
          OperationalTelemetry.query(
            :mean,
            {:ok, %{"scanned_rows" => 1}},
            System.monotonic_time()
          )
      end

      eventually(fn ->
        {:ok, %{"samples" => samples}} = OperationalHistory.snapshot(collector, limit: 1_000)
        Enum.any?(samples, &(&1["observed_at"] == time))
      end)
    end

    record.(1_000, :request)
    record.(1_100, :request)
    record.(1_150, :query)
    record.(1_200, :request)
    :atomics.put(clock, 1, 1_220)

    assert {:ok,
            %{
              "schema" => "wtr.operational-window-page.v1",
              "through" => 4,
              "samples" => [%{"sequence" => 2}],
              "cursor" => first,
              "window" => %{
                "from_at" => 1_070,
                "to_at" => 1_220,
                "duration_ms" => 150,
                "omitted_before" => 0,
                "samples" => graph
              }
            }} = OperationalHistory.window_page(collector, limit: 1, window_ms: 150)

    assert Enum.map(graph, & &1["sequence"]) == [2, 3, 4]

    record.(1_230, :request)

    assert {:ok,
            %{
              "through" => 4,
              "samples" => [%{"sequence" => 3}],
              "window" => %{"from_at" => 1_070, "to_at" => 1_220, "samples" => same_graph}
            }} =
             OperationalHistory.window_page(collector,
               limit: 1,
               window_ms: 150,
               cursor: first
             )

    assert Enum.map(same_graph, & &1["sequence"]) == [2, 3, 4]

    assert {:error, :invalid_cursor} =
             OperationalHistory.window_page(collector,
               event: "query.stop",
               limit: 1,
               window_ms: 150,
               cursor: first
             )

    assert {:error, :invalid_query} =
             OperationalHistory.window_page(collector, window_ms: 900_001)

    assert {:error, :invalid_query} =
             OperationalHistory.window_page(collector, window_ms: 150, window_ms: 100)

    :atomics.put(clock, 1, 1_601)

    assert {:error, :cursor_expired} =
             OperationalHistory.window_page(collector,
               limit: 1,
               window_ms: 150,
               cursor: first
             )

    :atomics.put(clock, 1, 2_000)

    for _ <- 1..1_002,
        do: OperationalTelemetry.request(:health, 200, System.monotonic_time())

    assert {:ok, %{"window" => %{"samples" => samples, "omitted_before" => 2}}} =
             OperationalHistory.window_page(collector, window_ms: 100, limit: 1_000)

    assert length(samples) == 1_000
    assert hd(samples)["sequence"] == 8
  end

  test "export batches resume without duplicates and disclose retention and restart gaps" do
    clock = :atomics.new(1, [])
    :atomics.put(clock, 1, 1_000)

    collector =
      start_supervised!(
        Supervisor.child_spec(
          {OperationalHistory,
           max_samples: 4, retention_ms: 50, clock: fn -> :atomics.get(clock, 1) end},
          id: make_ref(),
          restart: :temporary
        )
      )

    for _ <- 1..3, do: OperationalTelemetry.request(:health, 200, System.monotonic_time())

    eventually(fn ->
      match?({:ok, %{"samples" => [_, _, _]}}, OperationalHistory.snapshot(collector))
    end)

    assert {:ok,
            %{
              "schema" => "wtr.operational-export.v1",
              "continuity" => "snapshot",
              "lost_before" => 0,
              "through" => 3,
              "more" => true,
              "samples" => [%{"sequence" => 1}, %{"sequence" => 2}],
              "checkpoint" => first
            }} = OperationalHistory.export_batch(collector, limit: 2)

    :atomics.put(clock, 1, 1_001)
    OperationalTelemetry.request(:health, 200, System.monotonic_time())

    assert {:ok,
            %{
              "continuity" => "continuous",
              "through" => 4,
              "more" => false,
              "samples" => [%{"sequence" => 3}, %{"sequence" => 4}],
              "checkpoint" => second
            }} = OperationalHistory.export_batch(collector, checkpoint: first, limit: 2)

    assert {:ok,
            %{
              "continuity" => "continuous",
              "samples" => [],
              "checkpoint" => ^second
            }} = OperationalHistory.export_batch(collector, checkpoint: second, limit: 2)

    assert {:error, :invalid_cursor} =
             OperationalHistory.export_batch(collector,
               checkpoint: %{second | "after" => 99},
               limit: 2
             )

    :atomics.put(clock, 1, 1_052)
    OperationalTelemetry.request(:health, 200, System.monotonic_time())

    assert {:ok,
            %{
              "continuity" => "retention_gap",
              "lost_before" => 2,
              "samples" => [%{"sequence" => 5}],
              "checkpoint" => retained
            }} = OperationalHistory.export_batch(collector, checkpoint: first, limit: 2)

    GenServer.stop(collector)

    replacement =
      start_supervised!(
        Supervisor.child_spec(
          {OperationalHistory, clock: fn -> :atomics.get(clock, 1) end},
          id: make_ref(),
          restart: :temporary
        )
      )

    assert {:ok,
            %{
              "continuity" => "collector_restart",
              "lost_before" => nil,
              "samples" => [],
              "checkpoint" => replacement_checkpoint
            }} = OperationalHistory.export_batch(replacement, checkpoint: retained, limit: 2)

    refute replacement_checkpoint["epoch"] == retained["epoch"]
    assert replacement_checkpoint["after"] == 0
    assert {:error, :invalid_query} = OperationalHistory.export_batch(replacement, limit: 0)

    assert {:error, :invalid_cursor} =
             OperationalHistory.export_batch(replacement,
               checkpoint: Map.put(replacement_checkpoint, "extra", true)
             )
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

    eventually(fn ->
      case Server.operational_history(server, event: "runtime.sample") do
        {:ok, %{"samples" => [%{"measurements" => measurements, "metadata" => metadata} | _]}} ->
          metadata == %{"runtime" => "beam"} and
            Enum.all?(~w(beam_memory_bytes process_count port_count), fn key ->
              is_integer(measurements[key]) and measurements[key] > 0
            end)

        _ ->
          false
      end
    end)

    {:ok, store} = Server.child(server, :store)
    {:ok, sampler} = Server.child(server, :resource_sampler)
    assert {:error, :storage_unavailable} = Server.child(server, :operational_exporter)
    {:ok, %{"epoch" => epoch}} = Server.operational_history(server)
    Process.exit(sampler, :kill)

    eventually(fn ->
      match?(
        {:ok, replacement} when replacement != sampler,
        Server.child(server, :resource_sampler)
      )
    end)

    assert {:ok, ^store} = Server.child(server, :store)
    assert {:ok, %{"epoch" => ^epoch}} = Server.operational_history(server)
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
