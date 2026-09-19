defmodule Wotex.Tracker.Service.RouteHistoryTest do
  use ExUnit.Case, async: true

  import Wotex.Tracker.Service.Fixtures

  alias Wotex.Tracker.Evidence
  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.{Identifier, RouteHistory, Store, Update}

  @thing "urn:uuid:5b8f6ec0-21d6-4f23-943b-8df746bd0fc8"

  test "projects retained positions without bridging an unqualified materialisation" do
    c = service()
    put_position(c, "0", "first", c.now, -179.999, "valid")
    put_missing(c, "1", "missing", c.now + 1_000)
    put_position(c, "2", "second", c.now + 2_000, 179.999, "valid")

    assert {:ok, page} = Service.route_history(c.service, c.reader, c.scope, request(c, 3), c.now)
    assert page["schema"] == "wtr.route-page.v1"
    assert page["generation"] == "3"
    assert page["cursor"] == nil

    assert page["history"] == %{
             "after_generation" => "0",
             "last_generation" => "3",
             "record_count" => 3
           }

    route = page["route"]
    assert route["status"] == "partial"
    assert route["record_count"] == 3
    assert route["sample_count"] == 2
    assert route["point_count"] == 2
    assert route["segment_count"] == 2
    assert route["excluded_count"] == 1
    assert [%{"reason" => "missing_position"}] = route["excluded"]

    assert [%{"points" => [first]}, %{"points" => [second]}] = route["segments"]
    assert first["longitude"] == %{"type" => "number", "value" => -179.999}
    assert second["longitude"] == %{"type" => "number", "value" => 179.999}
    assert first["id"] =~ "wtr1_"

    assert [break] = route["breaks"]
    assert break["reason"] == "unqualified_materialisations"
    assert length(break["excluded_ids"]) == 1

    encoded = Service.Codec.encode!(page)
    refute encoded =~ "position-first"
    refute encoded =~ "capture-first"
    refute encoded =~ "private-position-source"
    refute encoded =~ "bundle_identity"
    refute encoded =~ "evidence_id"
  end

  test "retains core quality rejections and gap-separated segments" do
    c = service()
    put_position(c, "0", "first", c.now, 0.0, "valid")
    put_position(c, "1", "suspect", c.now + 1_000, 0.0001, "suspect")
    put_position(c, "2", "last", c.now + 2_000, 0.0002, "valid")

    assert {:ok, page} = Service.route_history(c.service, c.reader, c.scope, request(c, 3), c.now)
    route = page["route"]

    assert route["segment_count"] == 2
    assert route["rejected_count"] == 1
    assert [%{"reason" => "quality:suspect", "id" => rejected}] = route["rejected"]
    assert [break] = route["breaks"]
    assert break["reason"] == "rejected_samples"
    assert break["rejected_ids"] == [rejected]
  end

  test "continuations pin the snapshot and exact request and caller" do
    c = service()
    put_position(c, "0", "first", c.now, 0.0, "valid")
    put_position(c, "1", "second", c.now + 1_000, 0.0001, "valid")
    put_position(c, "2", "third", c.now + 2_000, 0.0002, "valid")
    request = request(c, 2)

    assert {:ok, first} = Service.route_history(c.service, c.reader, c.scope, request, c.now)
    assert first["generation"] == "3"
    assert first["route"]["point_count"] == 2
    assert is_binary(first["cursor"])

    put_position(c, "3", "later", c.now + 3_000, 0.0003, "valid")

    assert {:ok, second} =
             Service.route_history(
               c.service,
               c.reader,
               c.scope,
               %{request | "cursor" => first["cursor"]},
               c.now
             )

    assert second["generation"] == "3"
    assert second["history"]["record_count"] == 1
    assert second["route"]["point_count"] == 1
    assert second["cursor"] == nil

    for {token, changed} <- [
          {c.admin, %{request | "cursor" => first["cursor"]}},
          {c.reader, %{request | "max_gap_ms" => 9_999, "cursor" => first["cursor"]}},
          {c.reader, %{request | "page_size" => 1, "cursor" => first["cursor"]}}
        ] do
      assert {:error, %{"code" => "invalid_cursor"}} =
               Service.route_history(c.service, token, c.scope, changed, c.now)
    end
  end

  test "supports receiver fallback, suspect inclusion and half-open window filtering" do
    c = service()

    put_position(c, "0", "receiver", c.now, 0.0, "valid", %{
      "fix_at" => nil,
      "fix_clock" => "unknown"
    })

    put_missing(c, "1", "outside", c.now + 100)
    put_position(c, "2", "suspect", c.now + 1_000, 0.0001, "suspect")

    request =
      c
      |> request(3)
      |> Map.put("event_time", "trusted_fix_or_receiver")
      |> Map.put("qualities", ["valid", "suspect"])
      |> Map.put("from_at", c.now + 500)

    assert {:ok, page} = Service.route_history(c.service, c.reader, c.scope, request, c.now)
    assert page["route"]["status"] == "complete"
    assert page["route"]["record_count"] == 1
    assert page["route"]["point_count"] == 1
    assert page["route"]["excluded"] == []

    assert get_in(page, ["route", "segments", Access.at(0), "points", Access.at(0), "quality"]) ==
             "suspect"
  end

  test "orders untrusted fixes deterministically without admitting them" do
    c = service()

    put_position(c, "0", "untrusted", c.now, 0.0, "valid", %{
      "fix_at" => nil,
      "fix_clock" => "unknown"
    })

    assert {:ok, page} = Service.route_history(c.service, c.reader, c.scope, request(c, 1), c.now)
    assert page["route"]["status"] == "empty"
    assert page["route"]["rejected_count"] == 1
  end

  test "computes service breaks across reverse antimeridian and ordinary deltas" do
    c = service()
    put_position(c, "0", "east", c.now, 179.999, "valid")
    put_missing(c, "1", "date-line-gap", c.now + 1_000)
    put_position(c, "2", "west", c.now + 2_000, -179.999, "valid")
    put_missing(c, "3", "ordinary-gap", c.now + 3_000)
    put_position(c, "4", "nearby", c.now + 4_000, -179.998, "valid")

    assert {:ok, page} = Service.route_history(c.service, c.reader, c.scope, request(c, 5), c.now)
    assert page["route"]["segment_count"] == 3
    assert page["route"]["break_count"] == 2

    assert Enum.all?(
             page["route"]["breaks"],
             &(&1["reason"] == "unqualified_materialisations")
           )
  end

  test "reports ambiguous positions and rejects malformed stored position claims" do
    c = service()
    observation = observation(%{id: "capture-ambiguous", observed_at: c.now})

    evidence = [
      position_evidence(observation, "position-a", 0.0, "valid"),
      position_evidence(observation, "position-b", 0.0001, "valid")
    ]

    put_evidence(c, "0", observation, evidence)

    assert {:ok, page} =
             Service.route_history(c.service, c.reader, c.scope, request(c, 10), c.now)

    assert [%{"reason" => "ambiguous_positions"}] = page["route"]["excluded"]

    malformed_observation = observation(%{id: "capture-malformed", observed_at: c.now + 1})

    {:ok, malformed} =
      Evidence.new(%{
        id: "position-malformed",
        kind: :position,
        claim: %{"schema" => "wtr.position.v1"},
        source_observation_ids: [malformed_observation.id],
        evidence_ids: [],
        profile: {"fixture", "1"},
        decoder: {"fixture", "1"},
        confidence: :exact,
        reasons: ["fixture"],
        association_id: nil
      })

    put_evidence(c, "1", malformed_observation, [malformed])

    assert {:error, %{"code" => "storage_unavailable"}} =
             Service.route_history(c.service, c.reader, c.scope, request(c, 10), c.now)
  end

  test "admission is closed and storage corruption fails the whole page" do
    c = service()

    assert {:error, :invalid_request} = RouteHistory.run(nil, nil, nil, nil)

    for changed <- [
          %{"schema" => "wtr.route-page-request.v2"},
          %{"thing_id" => "not-a-thing"},
          %{"from_at" => c.now + 10_000},
          %{"event_time" => "receiver"},
          %{"qualities" => []},
          %{"qualities" => ["valid", "valid"]},
          %{"qualities" => ["invalid"]},
          %{"max_gap_ms" => 0},
          %{"max_gap_m" => 0},
          %{"page_size" => 0},
          %{"cursor" => 1},
          %{"extra" => true}
        ] do
      assert {:error, %{"code" => "invalid_request"}} =
               Service.route_history(
                 c.service,
                 c.reader,
                 c.scope,
                 Map.merge(request(c, 10), changed),
                 c.now
               )
    end

    assert {:error, %{"code" => "not_found"}} =
             Service.route_history(c.service, c.reader, c.scope, request(c, 10), c.now)

    put_corrupt(c, "0")

    assert {:error, %{"code" => "storage_unavailable"}} =
             Service.route_history(c.service, c.reader, c.scope, request(c, 10), c.now)

    assert {:error, %{"code" => "forbidden"}} =
             Service.route_history(c.service, c.reader, "other", request(c, 10), c.now)

    assert {:error, %{"code" => "invalid_request"}} =
             Service.route_history(c.service, c.reader, c.scope, [], c.now)

    malformed = service()
    put_corrupt(malformed, "0", %{"claims" => []})

    assert {:error, %{"code" => "storage_unavailable"}} =
             Service.route_history(
               malformed.service,
               malformed.reader,
               malformed.scope,
               request(malformed, 10),
               malformed.now
             )

    empty = service()
    put_evidence(empty, "0", observation(%{id: "capture-empty", observed_at: empty.now}), [])

    assert {:error, %{"code" => "storage_unavailable"}} =
             Service.route_history(
               empty.service,
               empty.reader,
               empty.scope,
               request(empty, 10),
               empty.now
             )
  end

  defp request(c, page_size),
    do: %{
      "schema" => "wtr.route-page-request.v1",
      "thing_id" => @thing,
      "from_at" => c.now - 1,
      "to_at" => c.now + 10_000,
      "event_time" => "trusted_fix",
      "qualities" => ["valid"],
      "max_gap_ms" => 10_000,
      "max_gap_m" => 10_000,
      "page_size" => page_size,
      "cursor" => nil
    }

  defp put_position(c, generation, id, observed_at, longitude, quality, changes \\ %{}) do
    observation = observation(%{id: "capture-#{id}", observed_at: observed_at})

    evidence =
      position_evidence(
        observation,
        "position-#{id}",
        longitude,
        quality,
        changes
      )

    put_evidence(c, generation, observation, [evidence])
  end

  defp put_missing(c, generation, id, observed_at) do
    observation = observation(%{id: "capture-#{id}", observed_at: observed_at})

    {:ok, evidence} =
      Evidence.new(%{
        id: "identity-#{id}",
        kind: :identity,
        claim: %{"fixture" => true},
        source_observation_ids: [observation.id],
        evidence_ids: [],
        profile: {"fixture", "1"},
        decoder: {"fixture", "1"},
        confidence: :exact,
        reasons: ["fixture"],
        association_id: nil
      })

    put_evidence(c, generation, observation, [evidence])
  end

  defp put_evidence(c, generation, observation, evidence) do
    {:ok, access} = Service.authorize(c.service, c.admin, c.scope, "ingest", c.now)

    claims =
      Enum.map(evidence, fn value ->
        {:ok, document} = Evidence.to_map(value)
        document
      end)

    {:ok, update} =
      Update.new(%{
        principal: access.principal,
        scope: c.scope,
        authority: access,
        operation_id: Identifier.uuid(),
        expected_generation: generation,
        request: %{"operation" => "route-fixture", "observation" => observation.id},
        now: c.now,
        observation: observation,
        records: [
          %{
            kind: "evidence",
            id: @thing,
            value: %{
              "claims" => claims,
              "public" => %{"id" => @thing, "claim_count" => length(claims)}
            }
          }
        ],
        events: [],
        publication: nil
      })

    assert {:ok, _} = Store.mutate(c.store, update)
  end

  defp put_corrupt(c, generation, value \\ nil) do
    {:ok, access} = Service.authorize(c.service, c.admin, c.scope, "ingest", c.now)

    value =
      value || %{"claims" => [%{"invalid" => true}], "public" => %{"id" => @thing}}

    {:ok, update} =
      Update.new(%{
        principal: access.principal,
        scope: c.scope,
        authority: access,
        operation_id: Identifier.uuid(),
        expected_generation: generation,
        request: %{"operation" => "corrupt-route-fixture"},
        now: c.now,
        observation: nil,
        records: [
          %{
            kind: "evidence",
            id: @thing,
            value: value
          }
        ],
        events: [],
        publication: nil
      })

    assert {:ok, _} = Store.mutate(c.store, update)
  end

  defp position_evidence(observation, id, longitude, quality, changes \\ %{}) do
    claim =
      Map.merge(
        %{
          "schema" => "wtr.position.v1",
          "latitude" => 0.0,
          "longitude" => longitude,
          "altitude_m" => nil,
          "speed_m_s" => nil,
          "horizontal_accuracy_m" => 5.0,
          "accuracy_kind" => "bound",
          "source" => "gnss",
          "fix_at" => observation.observed_at,
          "device_at" => nil,
          "received_at" => observation.observed_at,
          "fix_clock" => "trusted",
          "device_clock" => "unknown",
          "availability" => "available",
          "quality" => quality,
          "source_units" => %{
            "latitude" => "degree",
            "longitude" => "degree",
            "altitude" => nil,
            "speed" => nil,
            "accuracy" => "m",
            "fix_time" => "unix-ms",
            "device_time" => nil,
            "receiver_time" => "unix-ms"
          },
          "conversion_revision" => "fixture-v1",
          "receiver_observation_id" => observation.id,
          "raw" => %{"source" => "private-position-source"}
        },
        changes
      )

    {:ok, evidence} =
      Evidence.new(%{
        id: id,
        kind: :position,
        claim: claim,
        source_observation_ids: [observation.id],
        evidence_ids: [],
        profile: {"fixture", "1"},
        decoder: {"fixture", "1"},
        confidence: :exact,
        reasons: ["fixture"],
        association_id: nil
      })

    evidence
  end
end
