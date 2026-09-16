defmodule Wotex.Tracker.Service.AnalyticsTest do
  use ExUnit.Case, async: true

  import Wotex.Tracker.Service.Fixtures

  alias Wotex.Tracker.QuerySpec
  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.{Identifier, Projection, Store, Update}

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

  defp query_document(series, from_at, to_at, bucket_ms, options \\ []) do
    {:ok, spec} =
      QuerySpec.new(%{
        id: "temperature-history",
        revision: "service-query-v1",
        dataset: :measurements,
        measurement: "temperature",
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

  defp measurement(value, availability, quality),
    do: %{
      "kind" => "temperature",
      "value" => Projection.scalar(value),
      "unit" => "Cel",
      "availability" => availability,
      "quality" => quality
    }
end
