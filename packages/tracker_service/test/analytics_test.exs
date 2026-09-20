defmodule Wotex.Tracker.Service.AnalyticsTest do
  use ExUnit.Case, async: true

  import Wotex.Tracker.Service.Fixtures

  alias Exqlite.Sqlite3
  alias Wotex.Tracker.QuerySpec
  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.{AnalyticsCall, Codec, Identifier, Projection, SQL, Store, Update}

  test "materialized state history is queried at one restart-stable committed snapshot" do
    c = service()
    {thing, _td} = materialized(c)
    <<5, _temperature::16, rest::binary>> = elem(observation().payload, 1)

    {:ok, imported} =
      Service.submit(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        import_request(
          %{
            id: "second",
            observed_at: c.now + 1_000,
            payload: {:bytes, <<5, 6000::16, rest::binary>>}
          },
          "3"
        ),
        c.now
      )

    {:ok, _} =
      Service.associate(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        %{
          "thing_id" => thing,
          "observation_id" => imported["data"]["observation_id"],
          "owner_confirmed" => true,
          "expected_generation" => "4"
        },
        c.now
      )

    {:ok, _} =
      Service.materialize(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        %{"thing_id" => thing, "expected_generation" => "5"},
        c.now
      )

    document = query_document(thing, c.now, c.now + 2_000, 2_000)
    assert {:ok, result} = Service.analytics(c.service, c.reader, c.scope, document, c.now)
    assert result["snapshot"] =~ "wtr-service-snapshot-v1:sha256:"
    assert result["scanned_rows"] == 2
    assert result["selected_rows"] == 2
    assert result["qualified_rows"] == 2

    assert [series] = result["series"]
    assert series["id"] == thing
    assert [point] = series["points"]
    assert_in_delta(point["value"], 27.15, 1.0e-12)
    assert point["sample_count"] == 2
    assert point["last_event_at"] == c.now + 1_000

    GenServer.stop(c.store.pid)
    {restarted_store, _} = store(directory: c.directory, credentials: c.credentials)
    restarted = %{c.service | store: restarted_store}
    assert Service.analytics(restarted, c.reader, c.scope, document, c.now) == {:ok, result}
  end

  test "service extraction preserves zero and discloses unavailable and rejected quality rows" do
    c = service()
    put_state(c, "sensor", "0", c.now, 0, "available", "valid")
    put_state(c, "sensor", "1", c.now + 1, nil, "unavailable", "valid")
    put_state(c, "sensor", "2", c.now + 2, 9.5, "available", "suspect")
    put_state(c, "sensor", "3", c.now + 3, 100, "available", "invalid")

    document = query_document("sensor", c.now, c.now + 10, 10, aggregation: :last)
    assert {:ok, result} = Service.analytics(c.service, c.reader, c.scope, document, c.now)
    assert result["scanned_rows"] == 4
    assert result["selected_rows"] == 4
    assert result["qualified_rows"] == 1
    assert result["excluded_unavailable"] == 1
    assert result["excluded_quality"] == 2
    assert get_in(result, ["series", Access.at(0), "points", Access.at(0), "value"]) === 0

    all_qualities =
      query_document("sensor", c.now, c.now + 10, 10,
        aggregation: :last,
        qualities: [:valid, :suspect]
      )

    assert {:ok, included} = Service.analytics(c.service, c.reader, c.scope, all_qualities, c.now)
    assert included["qualified_rows"] == 2
    assert get_in(included, ["series", Access.at(0), "points", Access.at(0), "value"]) === 9.5
  end

  test "service rejects counter means and preserves the last value across a reset" do
    c = service()

    put_state(c, "sensor", "0", c.now, [
      measurement(17, "available", "valid", "movementCounter", "1")
    ])

    put_state(c, "sensor", "1", c.now + 1, [
      measurement(0, "available", "valid", "movementCounter", "1")
    ])

    last =
      query_document("sensor", c.now, c.now + 10, 10,
        measurement: "movementCounter",
        unit: "1",
        aggregation: :last
      )

    assert {:ok, result} = Service.analytics(c.service, c.reader, c.scope, last, c.now)
    assert get_in(result, ["series", Access.at(0), "points", Access.at(0), "value"]) === 0

    mean = last |> Map.put("aggregation", "mean") |> reidentify_query()

    assert {:error, %{"code" => "invalid_request"}} =
             Service.analytics(c.service, c.reader, c.scope, mean, c.now)
  end

  test "closed queries retain scope authorization and reject incompatible units" do
    c = service()
    put_state(c, "sensor", "0", c.now, 1, "available", "valid")
    document = query_document("sensor", c.now, c.now + 10, 10)

    assert {:error, %{"code" => "forbidden"}} =
             Service.analytics(c.service, c.reader, "other", document, c.now)

    assert {:error, %{"code" => "invalid_request"}} =
             Service.analytics(
               c.service,
               c.reader,
               c.scope,
               Map.put(document, "extra", true),
               c.now
             )

    assert {:error, %{"code" => "invalid_request"}} =
             Service.analytics(
               c.service,
               c.reader,
               c.scope,
               Map.put(document, "identity", "forged"),
               c.now
             )

    wrong_unit = query_document("sensor", c.now, c.now + 10, 10, unit: "mV")

    assert {:error, %{"code" => "conflict"}} =
             Service.analytics(c.service, c.reader, c.scope, wrong_unit, c.now)

    {:ok, spec} = QuerySpec.from_map(document)
    assert {:error, :invalid_query} = Store.authorized_analytics(c.store, nil, spec, c.now)
  end

  test "duplicate measurement entries in one committed state fail as unavailable storage" do
    c = service()

    measurement = measurement(1, "available", "valid")
    put_state(c, "sensor", "0", c.now, [measurement, measurement])
    document = query_document("sensor", c.now, c.now + 10, 10)

    assert {:error, %{"code" => "storage_unavailable"}} =
             Service.analytics(c.service, c.reader, c.scope, document, c.now)
  end

  test "malformed committed scalar and quality metadata fail closed" do
    c = service()
    put_state(c, "boolean", "0", c.now, true, "available", "valid")
    put_state(c, "quality", "1", c.now, 1, "available", "invented")

    for series <- ["boolean", "quality"] do
      assert {:error, %{"code" => "storage_unavailable"}} =
               Service.analytics(
                 c.service,
                 c.reader,
                 c.scope,
                 query_document(series, c.now, c.now + 10, 10),
                 c.now
               )
    end
  end

  test "query admission bounds global, per-principal and refresh starts" do
    c = service()
    {:ok, access} = Service.authorize(c.service, c.reader, c.scope, "read", c.now)
    {:ok, spec} = QuerySpec.from_map(query_document("sensor", c.now, c.now + 1, 1))
    table = c.store.analytics.slots

    for slot <- 1..2 do
      true = :ets.insert_new(table, {{:active, {:principal, access.principal}, slot}, self()})
    end

    assert {:error, :overloaded} = Store.authorized_analytics(c.store, access, spec, c.now)
    :ets.match_delete(table, {{:active, {:principal, access.principal}, :_}, :_})

    for slot <- 1..8 do
      true = :ets.insert_new(table, {{:active, :global, slot}, self()})
    end

    assert {:error, :overloaded} = Store.authorized_analytics(c.store, access, spec, c.now)
    :ets.match_delete(table, {{:active, :global, :_}, :_})

    window = div(System.monotonic_time(:millisecond), 1_000)
    :ets.insert(table, {{:rate, access.principal}, window, 15})
    assert {:ok, _} = Store.authorized_analytics(c.store, access, spec, c.now)
    assert {:error, :overloaded} = Store.authorized_analytics(c.store, access, spec, c.now)

    :ets.insert(table, {{:rate, access.principal}, 0, 16})
    before_renewal = div(System.monotonic_time(:millisecond), 1_000)
    assert {:ok, _} = Store.authorized_analytics(c.store, access, spec, c.now)
    after_renewal = div(System.monotonic_time(:millisecond), 1_000)
    assert [{{:rate, _}, renewed_window, 1}] = :ets.lookup(table, {:rate, access.principal})
    assert renewed_window in before_renewal..after_renewal
  end

  test "executor configuration and stage failures reject without retaining reservations" do
    c = service()
    {:ok, access} = Service.authorize(c.service, c.reader, c.scope, "read", c.now)
    {:ok, spec} = QuerySpec.from_map(query_document("sensor", c.now, c.now + 1, 1))

    assert {:error, :invalid_query} = AnalyticsCall.run(%{}, access, spec, c.now)

    before_failure = %{
      c.store.analytics
      | fault: fn
          :before_analytics -> :injected_failure
          _ -> :ok
        end
    }

    assert {:error, :storage_unavailable} =
             AnalyticsCall.run(before_failure, access, spec, c.now)

    opened_failure = %{
      c.store.analytics
      | fault: fn
          :analytics_opened -> :injected_failure
          _ -> :ok
        end
    }

    assert {:error, :storage_unavailable} =
             AnalyticsCall.run(opened_failure, access, spec, c.now)

    assert active_queries(c.store) == 0
  end

  test "a timed-out SQLite scan is cancelled and releases its query reservation" do
    c = service()
    {:ok, access} = Service.authorize(c.service, c.reader, c.scope, "read", c.now)
    GenServer.stop(c.store.pid)
    bulk_history(c.directory, c.scope, c.now, 100_000)

    {store, _} =
      store(directory: c.directory, credentials: c.credentials, timeout: 10, busy_timeout: 10)

    {:ok, spec} = QuerySpec.from_map(query_document("sensor", c.now, c.now + 1, 1))
    assert {:error, :deadline_exceeded} = Store.authorized_analytics(store, access, spec, c.now)
    eventually(fn -> active_queries(store) == 0 end)
    assert {:ok, %{"writable" => true}} = Store.readiness(store)
  end

  test "an abandoned caller cannot retain a query reservation" do
    parent = self()
    c = service(fault: blocking_analytics_fault(parent))
    {:ok, access} = Service.authorize(c.service, c.reader, c.scope, "read", c.now)
    {:ok, spec} = QuerySpec.from_map(query_document("sensor", c.now, c.now + 1, 1))

    caller =
      spawn(fn ->
        result = Store.authorized_analytics(c.store, access, spec, c.now)
        send(parent, {:abandoned_result, result})
      end)

    assert_receive {:analytics_blocked, worker}
    assert active_queries(c.store) == 1
    Process.exit(caller, :kill)
    send(worker, :continue)
    eventually(fn -> active_queries(c.store) == 0 end)
    refute_received {:abandoned_result, _}
  end

  test "store shutdown cancels an opened query connection" do
    parent = self()
    c = service(fault: blocking_analytics_fault(parent, :analytics_opened))
    {:ok, access} = Service.authorize(c.service, c.reader, c.scope, "read", c.now)
    {:ok, spec} = QuerySpec.from_map(query_document("sensor", c.now, c.now + 1, 1))

    spawn(fn ->
      result = Store.authorized_analytics(c.store, access, spec, c.now)
      send(parent, {:shutdown_result, result})
    end)

    assert_receive {:analytics_blocked, worker}
    GenServer.stop(c.store.pid)
    send(worker, :continue)
    assert_receive {:shutdown_result, {:error, :deadline_exceeded}}
  end

  defp query_document(series, from_at, to_at, bucket_ms, options \\ []) do
    {:ok, spec} =
      QuerySpec.new(%{
        id: "temperature-history",
        revision: "service-query-v1",
        dataset: :measurements,
        measurement: Keyword.get(options, :measurement, "temperature"),
        unit: Keyword.get(options, :unit, "Cel"),
        series: [series],
        qualities: Keyword.get(options, :qualities, [:valid]),
        from_at: from_at,
        to_at: to_at,
        timezone: "Etc/UTC",
        bucket_ms: bucket_ms,
        aggregation: Keyword.get(options, :aggregation, :mean),
        order: :ascending,
        max_points: 10
      })

    {:ok, document} = QuerySpec.to_map(spec)
    document
  end

  defp put_state(c, id, generation, event_at, value, availability, quality) do
    put_state(c, id, generation, event_at, [measurement(value, availability, quality)])
  end

  defp put_state(c, id, generation, event_at, measurements) do
    {:ok, access} = Service.authorize(c.service, c.admin, c.scope, "ingest", c.now)

    {:ok, update} =
      Update.new(%{
        principal: access.principal,
        scope: c.scope,
        authority: access,
        operation_id: Identifier.uuid(),
        expected_generation: generation,
        request: %{"operation" => "state-fixture", "generation" => generation},
        now: c.now,
        observation: nil,
        records: [
          %{
            kind: "state",
            id: id,
            value: %{
              "public" => %{
                "id" => id,
                "observed_at" => Projection.scalar(event_at),
                "measurements" => measurements
              }
            }
          }
        ],
        events: [],
        publication: nil
      })

    assert {:ok, _} = Store.mutate(c.store, update)
  end

  defp measurement(value, availability, quality, kind \\ "temperature", unit \\ "Cel"),
    do: %{
      "kind" => kind,
      "value" => Projection.scalar(value),
      "unit" => unit,
      "availability" => availability,
      "quality" => quality
    }

  defp reidentify_query(document) do
    material = Map.delete(document, "identity")
    Map.put(material, "identity", "wtr-json-v1:sha256:" <> Codec.digest(material))
  end

  defp bulk_history(directory, scope, event_at, count) do
    document = %{
      "public" => %{
        "observed_at" => Projection.scalar(event_at),
        "measurements" => [measurement(1, "available", "valid")]
      }
    }

    {:ok, db} = Sqlite3.open(Path.join(directory, "tracker.db"), mode: :readwrite)

    try do
      SQL.execute!(db, "BEGIN IMMEDIATE")
      SQL.rows!(db, "INSERT OR REPLACE INTO scopes VALUES(?,?)", [scope, count])

      SQL.rows!(
        db,
        """
        WITH RECURSIVE sequence(value) AS (
          SELECT 1 UNION ALL SELECT value + 1 FROM sequence WHERE value < ?
        )
        INSERT INTO records(scope,kind,id,generation,document)
        SELECT ?,'state','sensor',value,? FROM sequence
        """,
        [count, scope, Codec.encode!(document)]
      )

      SQL.execute!(db, "COMMIT")
    after
      SQL.rollback(db)
      Sqlite3.close(db)
    end
  end

  defp active_queries(store) do
    store.analytics.slots
    |> :ets.tab2list()
    |> Enum.count(fn
      {{:active, :global, _}, _} -> true
      _ -> false
    end)
  end

  defp blocking_analytics_fault(receiver, blocked_phase \\ :before_analytics) do
    fn phase ->
      if phase == blocked_phase do
        send(receiver, {:analytics_blocked, self()})

        receive do
          :continue -> :ok
        after
          1_000 -> :ok
        end
      else
        :ok
      end
    end
  end

  defp eventually(check, attempts \\ 200)
  defp eventually(check, 0), do: assert(check.())

  defp eventually(check, attempts) do
    unless check.() do
      Process.sleep(5)
      eventually(check, attempts - 1)
    end
  end
end
