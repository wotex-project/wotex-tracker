defmodule Wotex.Tracker.Service.AnalyticsPageTest do
  use ExUnit.Case, async: true

  import Wotex.Tracker.Service.Fixtures

  alias Wotex.Tracker.QuerySpec
  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.{Identifier, Projection, Store, Update}

  test "pages retain their first committed generation while writes continue" do
    c = service()
    put_history(c, 5)
    query = query_document(c, :ascending)
    request = page_request(query, 2)

    assert {:ok, first} = Service.analytics_page(c.service, c.reader, c.scope, request, c.now)
    assert first["schema"] == "wtr.query-page.v1"
    assert first["algorithm"] == "snapshot-pinned-bucket-pages-v1"
    assert first["generation"] == "5"
    assert first["page"] == %{"index" => 0, "from_at" => c.now, "to_at" => c.now + 2_000}
    assert values(first) == [1.0, 2.0]
    assert is_binary(first["cursor"])
    assert first["identity"] =~ "wtr-analytics-page-v1:sha256:"
    snapshot = first["result"]["snapshot"]

    put_state(c, "5", c.now + 2_500, 99)

    assert {:ok, second} =
             Service.analytics_page(
               c.service,
               c.reader,
               c.scope,
               %{request | "cursor" => first["cursor"]},
               c.now
             )

    assert second["generation"] == "5"
    assert second["result"]["snapshot"] == snapshot

    assert second["page"] == %{
             "index" => 1,
             "from_at" => c.now + 2_000,
             "to_at" => c.now + 4_000
           }

    assert values(second) == [3.0, 4.0]

    assert {:ok, third} =
             Service.analytics_page(
               c.service,
               c.reader,
               c.scope,
               %{request | "cursor" => second["cursor"]},
               c.now
             )

    assert third["generation"] == "5"
    assert third["result"]["snapshot"] == snapshot

    assert third["page"] == %{
             "index" => 2,
             "from_at" => c.now + 4_000,
             "to_at" => c.now + 5_000
           }

    assert values(third) == [5.0]
    assert third["cursor"] == nil

    assert {:ok, latest} =
             Service.analytics_page(c.service, c.reader, c.scope, page_request(query, 5), c.now)

    assert latest["generation"] == "6"
    assert values(latest) == [1.0, 2.0, 51.0, 4.0, 5.0]
  end

  test "descending pages cover each bucket once in global order" do
    c = service()
    put_history(c, 5)
    request = page_request(query_document(c, :descending), 2)

    assert {:ok, first} = Service.analytics_page(c.service, c.reader, c.scope, request, c.now)
    assert values(first) == [5.0, 4.0]
    assert first["page"]["from_at"] == c.now + 3_000
    assert first["page"]["to_at"] == c.now + 5_000

    assert {:ok, second} =
             Service.analytics_page(
               c.service,
               c.reader,
               c.scope,
               %{request | "cursor" => first["cursor"]},
               c.now
             )

    assert values(second) == [3.0, 2.0]

    assert {:ok, third} =
             Service.analytics_page(
               c.service,
               c.reader,
               c.scope,
               %{request | "cursor" => second["cursor"]},
               c.now
             )

    assert values(third) == [1.0]
    assert third["cursor"] == nil
  end

  test "continuations bind the exact query, page size, caller and valid page range" do
    c = service()
    put_history(c, 3)
    query = query_document(c, :ascending)
    request = page_request(query, 1)
    assert {:ok, first} = Service.analytics_page(c.service, c.reader, c.scope, request, c.now)

    altered_query = query_document(c, :descending)

    for {token, changed} <- [
          {c.reader, %{request | "page_size" => 2, "cursor" => first["cursor"]}},
          {c.reader, %{request | "query" => altered_query, "cursor" => first["cursor"]}},
          {c.admin, %{request | "cursor" => first["cursor"]}}
        ] do
      assert {:error, %{"code" => "invalid_cursor"}} =
               Service.analytics_page(c.service, token, c.scope, changed, c.now)
    end

    {:ok, access} = Service.authorize(c.service, c.reader, c.scope, "read", c.now)
    {:ok, spec} = QuerySpec.from_map(query)

    assert {:error, :invalid_cursor} =
             Store.authorized_analytics_at(c.store, access, spec, c.now, 4)

    {:ok, admin} = Service.authorize(c.service, c.admin, c.scope, "admin", c.now)

    {:ok, revocation} =
      Update.new(%{
        principal: admin.principal,
        scope: c.scope,
        authority: admin,
        operation_id: Identifier.uuid(),
        expected_generation: "3",
        request: %{"operation" => "revoke-page-reader"},
        now: c.now,
        observation: nil,
        records: [%{kind: "access", id: "reader", value: %{"revoked" => true}}],
        events: [%{"type" => "access.revoked", "data" => %{"credential_id" => "reader"}}],
        publication: nil
      })

    assert {:ok, _} = Store.mutate(c.store, revocation)

    assert {:error, %{"code" => "unauthorized"}} =
             Service.analytics_page(
               c.service,
               c.reader,
               c.scope,
               %{request | "cursor" => first["cursor"]},
               c.now
             )
  end

  test "request admission is closed and distinguishes malformed requests from cursors" do
    c = service()
    query = query_document(c, :ascending)

    for request <- [
          %{},
          Map.delete(page_request(query, 1), "cursor"),
          Map.put(page_request(query, 1), "extra", true),
          %{page_request(query, 1) | "schema" => "wtr.query-page-request.v2"},
          %{page_request(query, 1) | "page_size" => 0},
          %{page_request(query, 1) | "cursor" => 1}
        ] do
      assert {:error, %{"code" => "invalid_request"}} =
               Service.analytics_page(c.service, c.reader, c.scope, request, c.now)
    end

    assert {:error, %{"code" => "invalid_cursor"}} =
             Service.analytics_page(
               c.service,
               c.reader,
               c.scope,
               %{page_request(query, 1) | "cursor" => "wtrc1.invalid"},
               c.now
             )
  end

  defp page_request(query, page_size),
    do: %{
      "schema" => "wtr.query-page-request.v1",
      "query" => query,
      "page_size" => page_size,
      "cursor" => nil
    }

  defp query_document(c, order) do
    {:ok, spec} =
      QuerySpec.new(%{
        id: "temperature-history",
        revision: "paged-service-query-v1",
        dataset: :measurements,
        measurement: "temperature",
        unit: "Cel",
        series: ["sensor"],
        qualities: [:valid],
        from_at: c.now,
        to_at: c.now + 5_000,
        timezone: "Etc/UTC",
        bucket_ms: 1_000,
        aggregation: :mean,
        order: order,
        max_points: 5
      })

    {:ok, document} = QuerySpec.to_map(spec)
    document
  end

  defp put_history(c, count) do
    Enum.each(1..count, fn value ->
      put_state(c, Integer.to_string(value - 1), c.now + (value - 1) * 1_000, value)
    end)
  end

  defp put_state(c, expected_generation, event_at, value) do
    {:ok, access} = Service.authorize(c.service, c.admin, c.scope, "ingest", c.now)

    {:ok, update} =
      Update.new(%{
        principal: access.principal,
        scope: c.scope,
        authority: access,
        operation_id: Identifier.uuid(),
        expected_generation: expected_generation,
        request: %{"operation" => "analytics-page-fixture", "event_at" => event_at},
        now: c.now,
        observation: nil,
        records: [
          %{
            kind: "state",
            id: "sensor",
            value: %{
              "public" => %{
                "id" => "sensor",
                "observed_at" => Projection.scalar(event_at),
                "measurements" => [
                  %{
                    "kind" => "temperature",
                    "value" => Projection.scalar(value),
                    "unit" => "Cel",
                    "availability" => "available",
                    "quality" => "valid"
                  }
                ]
              }
            }
          }
        ],
        events: [],
        publication: nil
      })

    assert {:ok, _} = Store.mutate(c.store, update)
  end

  defp values(page) do
    page["result"]["series"]
    |> hd()
    |> Map.fetch!("points")
    |> Enum.map(& &1["value"])
  end
end
