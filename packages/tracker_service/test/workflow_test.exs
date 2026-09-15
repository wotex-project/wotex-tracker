defmodule Wotex.Tracker.WorkflowTest do
  @moduledoc false
  use ExUnit.Case, async: true
  import Wotex.Tracker.Service.Fixtures
  alias Wotex.Tracker.Catalogue
  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.{Codec, Credentials, Identifier, Store}

  setup do
    service()
  end

  test "committed imports replay before interpreting a changed catalogue", context do
    operation = Identifier.uuid()
    request = import_request()
    assert {:ok, receipt} = submit(context, operation, request)
    {:ok, empty} = Catalogue.new([])
    changed = %{context | service: %{context.service | catalogue: empty}}
    assert {:ok, ^receipt} = submit(changed, operation, request)

    assert {:error, %{"code" => "idempotency_conflict", "outcome" => "not_committed"}} =
             submit(changed, operation, import_request(%{observed_at: context.now + 1}))

    assert {:error, %{"code" => "operation_expired"}} =
             submit(%{changed | now: context.now + 604_800_000}, operation, request)

    assert {:error, :invalid_request} =
             Store.replay(context.store, nil, "ingest", %{}, context.now)

    assert {:error, :invalid_query} =
             Store.authorized_operation(context.store, nil, nil, context.now)
  end

  test "explicit enrollment and materialisation retain exact receipts, validated TDs and private lineage",
       context do
    assert {:ok, imported} = submit(context, Identifier.uuid(), import_request())
    observation = imported["data"]["observation_id"]
    request = enrollment_request(observation)
    operation = Identifier.uuid()
    assert {:ok, enrolled} = enroll(context, operation, request)
    thing = enrolled["data"]["thing_id"]
    assert "urn:uuid:" <> uuid = thing
    assert Identifier.operation?(uuid)
    assert {:ok, ^enrolled} = enroll(context, operation, request)

    assert {:ok, %{"value" => enrollment}} = get(context, "enrollments", thing)
    assert enrollment["owner_confirmed"]
    assert enrollment["identity_strategy"] == "operator-pseudonym-v1"

    materialize_request = %{"thing_id" => thing, "expected_generation" => "2"}
    materialize_operation = Identifier.uuid()

    assert {:ok, materialised} = materialize(context, materialize_operation, materialize_request)
    assert materialised["generation"] == "3"
    assert materialised["publication"] == nil
    assert {:ok, %{"value" => td}} = get(context, "things", thing)
    assert {:ok, _} = Wotex.ThingDescription.from_map(td)
    assert td["id"] == thing
    assert td["title"] == "Workshop sensor"
    assert td["security"] == ["bearer"]
    assert map_size(td["properties"]) == 10

    assert [form, stream] = td["properties"]["temperature"]["forms"]
    assert stream["op"] == ["observeproperty", "unobserveproperty"]
    assert stream["subprotocol"] == "sse"
    assert td["properties"]["temperature"]["observable"]
    assert form["op"] == "readproperty"

    assert form["href"] ==
             "http://127.0.0.1:45678/api/v1/scopes/workshop/things/" <>
               URI.encode(thing, &URI.char_unreserved?/1) <> "/properties/temperature"

    public = Codec.encode!(%{"td" => td, "enrollment" => enrollment})

    for private <- [
          "private-hardware",
          "cbb8334c884f",
          "private-receiver",
          "observation-1",
          "owner"
        ],
        do: refute(public =~ ~s("#{private}"))

    assert {:ok, %{"value" => state}} = get(context, "state", thing)
    assert state["observation_id"] == observation

    assert Enum.find(state["measurements"], &(&1["kind"] == "temperature"))["value"]["value"] ===
             24.3

    assert {:ok, bytes} =
             Service.raw_evidence(
               context.service,
               context.admin,
               context.scope,
               thing,
               context.now
             )

    assert Enum.any?(Codec.decode!(bytes), &(&1["claim"]["strategy"] == "operator-pseudonym-v1"))
    assert bytes =~ "cbb8334c884f"

    {:ok, empty} = Catalogue.new([])
    changed = %{context | service: %{context.service | catalogue: empty}}
    assert {:ok, ^enrolled} = enroll(changed, operation, request)
    assert {:ok, ^materialised} = materialize(changed, materialize_operation, materialize_request)

    assert {:error, %{"code" => "revision_mismatch"}} =
             materialize(changed, Identifier.uuid(), %{
               materialize_request
               | "expected_generation" => "3"
             })

    GenServer.stop(context.store.pid)
    {store, _} = store(directory: context.directory, credentials: context.credentials)
    restarted = %{context | store: store, service: %{context.service | store: store}}

    assert {:ok, ^materialised} =
             materialize(restarted, materialize_operation, materialize_request)

    assert {:ok, %{"value" => ^td}} = get(restarted, "things", thing)
  end

  test "unresolved, missing, malformed and stale inputs cannot create Things", context do
    assert {:ok, result} =
             submit(context, Identifier.uuid(), import_request(%{ingress: "imported"}))

    request = enrollment_request(result["data"]["observation_id"])
    assert {:error, %{"code" => "unresolved"}} = enroll(context, Identifier.uuid(), request)

    assert {:error, %{"code" => "not_found"}} =
             enroll(context, Identifier.uuid(), %{request | "observation_id" => "missing"})

    assert {:error, %{"code" => "conflict"}} =
             enroll(context, Identifier.uuid(), %{request | "expected_generation" => "2"})

    for invalid <- [
          nil,
          %{},
          Map.put(request, "owner_confirmed", false),
          Map.put(request, "title", ""),
          Map.put(request, "expected_generation", "01"),
          Map.put(request, "extra", true)
        ] do
      assert {:error, %{"code" => "invalid_request"}} =
               enroll(context, Identifier.uuid(), invalid)
    end

    for invalid <- [
          nil,
          %{},
          %{"thing_id" => "raw-mac", "expected_generation" => "1"},
          %{"thing_id" => "urn:uuid:" <> Identifier.uuid(), "expected_generation" => "-1"}
        ] do
      assert {:error, %{"code" => "invalid_request"}} =
               materialize(context, Identifier.uuid(), invalid)
    end

    assert {:error, %{"code" => "invalid_request"}} = enroll(context, "not-uuid", request)

    assert {:error, %{"code" => "forbidden"}} =
             enroll(%{context | admin: context.reader}, Identifier.uuid(), request)

    assert {:error, %{"code" => "not_found"}} =
             materialize(context, Identifier.uuid(), %{
               "thing_id" => "urn:uuid:" <> Identifier.uuid(),
               "expected_generation" => "1"
             })

    assert {:ok, %{"items" => [], "generation" => "1"}} =
             Service.list(
               context.service,
               context.admin,
               context.scope,
               "things",
               %{},
               context.now
             )
  end

  test "enroll authority can derive initial state from admitted evidence without an ingest grant",
       context do
    assert {:ok, result} = submit(context, Identifier.uuid(), import_request())
    token = Credentials.generate_token()
    {:ok, digest} = Credentials.token_digest(token)

    {:ok, credentials} =
      Credentials.new(%{
        instance_id: "enrollment-only",
        secret_key: :crypto.strong_rand_bytes(32),
        entries: [
          %{
            id: "enroller",
            principal: "owner",
            token_sha256: digest,
            grants: %{context.scope => ["enroll"]},
            expires_at: context.now + 1000
          }
        ]
      })

    GenServer.stop(context.store.pid)
    {store, _} = store(directory: context.directory, credentials: credentials)

    context = %{
      context
      | store: store,
        admin: token,
        credentials: credentials,
        service: %{context.service | store: store, credentials: credentials}
    }

    assert {:ok, enrolled} =
             enroll(
               context,
               Identifier.uuid(),
               enrollment_request(result["data"]["observation_id"])
             )

    assert {:ok, _} =
             materialize(context, Identifier.uuid(), %{
               "thing_id" => enrolled["data"]["thing_id"],
               "expected_generation" => "2"
             })

    assert {:error, %{"code" => "forbidden"}} =
             submit(context, Identifier.uuid(), import_request(%{id: "new"}, "3"))
  end

  test "acknowledgement loss remains unknown and receipt lookup resolves it without retrying",
       _context do
    context =
      service(
        fault: fn
          :after_commit -> :abort
          _ -> :ok
        end
      )

    operation = Identifier.uuid()
    request = import_request()

    assert {:ok, %{"outcome" => "unknown", "operation_id" => ^operation}} =
             submit(context, operation, request)

    assert {:ok, %{"outcome" => "committed"} = receipt} =
             Service.operation(
               context.service,
               context.admin,
               context.scope,
               operation,
               context.now
             )

    assert {:ok, ^receipt} = submit(context, operation, request)
    GenServer.stop(context.store.pid)

    assert {:error, %{"code" => "storage_unavailable", "outcome" => "not_committed"}} =
             submit(context, Identifier.uuid(), import_request(%{id: "never-attempted"}, "1"))

    assert {:error, %{"code" => "storage_unavailable"}} = get(context, "state", "missing")

    before_commit =
      service(
        fault: fn
          :before_commit -> :abort
          _ -> :ok
        end
      )

    assert {:error, %{"code" => "storage_unavailable", "outcome" => "not_committed"}} =
             submit(before_commit, Identifier.uuid(), request)
  end

  defp enrollment_request(id),
    do: %{
      "observation_id" => id,
      "title" => "Workshop sensor",
      "owner_confirmed" => true,
      "expected_generation" => "1"
    }

  defp submit(c, operation, request),
    do: Service.submit(c.service, c.admin, c.scope, operation, request, c.now)

  defp enroll(c, operation, request),
    do: Service.enroll(c.service, c.admin, c.scope, operation, request, c.now)

  defp materialize(c, operation, request),
    do: Service.materialize(c.service, c.admin, c.scope, operation, request, c.now)

  defp get(c, resource, id), do: Service.get(c.service, c.admin, c.scope, resource, id, c.now)
end
