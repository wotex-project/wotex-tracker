defmodule Wotex.Tracker.ServiceTest do
  @moduledoc false
  use ExUnit.Case, async: true
  import Wotex.Tracker.Service.Fixtures
  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.{Codec, Identifier, Store}

  setup do
    service()
  end

  test "access projects only the current credential identity and exact scope grants", context do
    assert {:ok,
            %{
              "schema" => "wtr.access.v1",
              "credential_id" => "admin",
              "principal" => "owner",
              "scope" => "workshop",
              "permissions" => ~w(admin enroll ingest interact raw read),
              "expires_at" => expires_at
            } = access} =
             Service.access(
               context.service,
               context.admin,
               context.scope,
               context.now
             )

    assert expires_at == context.now + 1_000_000_000
    refute Codec.encode!(access) =~ context.admin

    assert {:ok,
            %{
              "credential_id" => "reader",
              "principal" => "viewer",
              "permissions" => ["read"]
            }} =
             Service.access(
               context.service,
               context.reader,
               context.scope,
               context.now
             )

    assert {:error, %{"code" => "unauthorized"}} =
             Service.access(context.service, "invalid", context.scope, context.now)
  end

  test "public import, inspection and private raw export keep evidence and browser types separate",
       context do
    operation = Identifier.uuid()

    request =
      import_request(%{
        source: %{
          "integer" => 1,
          "float" => 1.0,
          "wide" => 9_007_199_254_740_993,
          "false" => false,
          "null" => nil
        }
      })

    assert {:ok, result} =
             Service.submit(
               context.service,
               context.admin,
               context.scope,
               operation,
               request,
               context.now
             )

    assert result["outcome"] == "committed"
    assert result["generation"] == "1"
    id = result["data"]["observation_id"]
    assert String.starts_with?(id, "wtr1_")

    assert {:ok, ^result} =
             Service.submit(
               context.service,
               context.admin,
               context.scope,
               operation,
               request,
               context.now
             )

    assert {:ok, ^result} =
             Service.operation(
               context.service,
               context.admin,
               context.scope,
               operation,
               context.now
             )

    assert {:error, %{"code" => "not_found"}} =
             Service.operation(
               context.service,
               context.reader,
               context.scope,
               operation,
               context.now
             )

    assert {:ok, %{"value" => %{"id" => ^id, "ingress" => "ble"}}} =
             Service.get(
               context.service,
               context.reader,
               context.scope,
               "observations",
               id,
               context.now
             )

    assert {:ok, %{"value" => %{"status" => "resolved"}}} =
             Service.get(
               context.service,
               context.reader,
               context.scope,
               "resolutions",
               id,
               context.now
             )

    assert {:ok, %{"value" => %{"claim_count" => count}}} =
             Service.get(
               context.service,
               context.reader,
               context.scope,
               "evidence",
               id,
               context.now
             )

    assert count > 10

    assert {:ok, %{"value" => state}} =
             Service.get(context.service, context.reader, context.scope, "state", id, context.now)

    assert state["positions"] == []

    assert Enum.find(state["measurements"], &(&1["kind"] == "temperature"))["value"] == %{
             "type" => "number",
             "value" => 24.3
           }

    assert {:error, %{"code" => "forbidden"}} =
             Service.raw_observation(
               context.service,
               context.reader,
               context.scope,
               id,
               context.now
             )

    assert {:error, %{"code" => "forbidden"}} =
             Service.raw_evidence(context.service, context.reader, context.scope, id, context.now)

    assert {:ok, bytes} =
             Service.raw_observation(
               context.service,
               context.admin,
               context.scope,
               id,
               context.now
             )

    assert Codec.decode!(bytes) === request["observation"]

    assert {:ok, evidence} =
             Service.raw_evidence(context.service, context.admin, context.scope, id, context.now)

    assert evidence =~ "cbb8334c884f"

    assert {:ok, %{"items" => [item]}} =
             Service.list(
               context.service,
               context.reader,
               context.scope,
               "observations",
               %{},
               context.now
             )

    public = Codec.encode!(item)

    for private <- [
          "private-hardware",
          "cbb8334c884f",
          "9007199254740993",
          "addressing",
          "payload"
        ],
        do: refute(public =~ private)
  end

  test "snapshot and replay preserve stable event IDs and scope/principal/resource bindings",
       context do
    assert {:ok, empty} =
             Service.list(
               context.service,
               context.admin,
               context.scope,
               "state",
               %{},
               context.now
             )

    assert empty["generation"] == "0"

    assert {:ok, %{"items" => []}} =
             Service.events(
               context.service,
               context.admin,
               context.scope,
               empty["stream_cursor"],
               context.now
             )

    for generation <- 0..1 do
      request = import_request(%{id: "private-id-#{generation}"}, Integer.to_string(generation))

      assert {:ok, _} =
               Service.submit(
                 context.service,
                 context.admin,
                 context.scope,
                 Identifier.uuid(),
                 request,
                 context.now
               )
    end

    assert {:ok, %{"items" => [first, second], "cursor" => last_cursor}} =
             Service.events(
               context.service,
               context.admin,
               context.scope,
               empty["stream_cursor"],
               context.now
             )

    assert {first["id"], second["id"]} == {"1", "2"}

    assert {:ok, %{"items" => [replayed]}} =
             Service.events(
               context.service,
               context.admin,
               context.scope,
               first["cursor"],
               context.now
             )

    assert replayed["id"] == second["id"]

    assert {:ok, %{"items" => []}} =
             Service.events(
               context.service,
               context.admin,
               context.scope,
               last_cursor,
               context.now
             )

    assert {:error, %{"code" => "invalid_cursor"}} =
             Service.events(
               context.service,
               context.reader,
               context.scope,
               last_cursor,
               context.now
             )

    assert {:ok, page} =
             Service.list(
               context.service,
               context.admin,
               context.scope,
               "observations",
               %{"limit" => 1},
               context.now
             )

    assert {:ok, next} =
             Service.list(
               context.service,
               context.admin,
               context.scope,
               "observations",
               %{"cursor" => page["cursor"]},
               context.now
             )

    assert length(next["items"]) == 1
    refute next["items"] == page["items"]

    assert {:error, %{"code" => "invalid_cursor"}} =
             Service.list(
               context.service,
               context.reader,
               context.scope,
               "observations",
               %{"cursor" => page["cursor"]},
               context.now
             )

    assert {:error, %{"code" => "invalid_cursor"}} =
             Service.list(
               context.service,
               context.admin,
               context.scope,
               "resolutions",
               %{"cursor" => page["cursor"]},
               context.now
             )

    assert {:error, %{"code" => "invalid_cursor"}} =
             Service.list(
               context.service,
               context.admin,
               context.scope,
               "observations",
               %{"cursor" => page["cursor"], "limit" => 2},
               context.now
             )

    assert {:error, %{"code" => "cursor_expired"}} =
             Service.list(
               context.service,
               context.admin,
               context.scope,
               "observations",
               %{"cursor" => page["cursor"]},
               context.now + 604_800_000
             )
  end

  test "unknown imported observations are retained as unknown without fabricated measurements",
       context do
    assert {:ok, result} =
             Service.submit(
               context.service,
               context.admin,
               context.scope,
               Identifier.uuid(),
               import_request(%{ingress: "imported"}),
               context.now
             )

    id = result["data"]["observation_id"]

    assert {:ok, %{"value" => %{"status" => "unknown"}}} =
             Service.get(
               context.service,
               context.reader,
               context.scope,
               "resolutions",
               id,
               context.now
             )

    assert {:ok, %{"value" => %{"measurements" => []}}} =
             Service.get(context.service, context.reader, context.scope, "state", id, context.now)

    assert {:ok, "[]"} =
             Service.raw_evidence(context.service, context.admin, context.scope, id, context.now)
  end

  test "every mutation is scoped and errors are bounded, redacted, and precise about commit",
       context do
    operation = Identifier.uuid()

    assert {:error, %{"code" => "forbidden", "outcome" => "not_committed"}} =
             Service.submit(
               context.service,
               context.reader,
               context.scope,
               operation,
               import_request(),
               context.now
             )

    assert {:error, %{"code" => "unauthorized", "operation_id" => nil}} =
             Service.submit(
               context.service,
               "bad",
               context.scope,
               "private-secret",
               import_request(),
               context.now
             )

    assert {:error, %{"code" => "invalid_request"}} =
             Service.submit(
               context.service,
               context.admin,
               context.scope,
               "not-a-uuid",
               import_request(),
               context.now
             )

    for request <- [
          nil,
          %{},
          %{"observation" => %{}},
          %{import_request() | "expected_generation" => "01"}
        ] do
      assert {:error, %{"code" => "invalid_request"}} =
               Service.submit(
                 context.service,
                 context.admin,
                 context.scope,
                 operation,
                 request,
                 context.now
               )
    end

    assert {:error, %{"code" => "invalid_observation"}} =
             Service.submit(
               context.service,
               context.admin,
               context.scope,
               operation,
               %{import_request() | "observation" => %{"secret" => "private-hardware"}},
               context.now
             )

    assert {:error, %{"code" => "unsupported"}} =
             Service.list(
               context.service,
               context.admin,
               context.scope,
               "ble_scan",
               %{},
               context.now
             )

    for params <- [nil, %{"extra" => true}, %{"limit" => 101}] do
      assert {:error, %{"code" => "invalid_request"}} =
               Service.list(
                 context.service,
                 context.admin,
                 context.scope,
                 "state",
                 params,
                 context.now
               )
    end

    assert {:error, %{"code" => "not_found"}} =
             Service.get(
               context.service,
               context.reader,
               context.scope,
               "things",
               "missing",
               context.now
             )

    assert {:error, %{"code" => "invalid_query"}} =
             Service.get(
               context.service,
               context.reader,
               context.scope,
               "things",
               nil,
               context.now
             )

    assert {:error, %{"code" => "invalid_request"}} =
             Service.operation(context.service, context.admin, context.scope, "bad", context.now)
  end

  test "administrative revocation immediately rejects subsequent reads and mutation replay",
       context do
    assert {:error, %{"code" => "forbidden", "outcome" => "not_committed"}} =
             Service.revoke(
               context.service,
               context.reader,
               context.scope,
               Identifier.uuid(),
               %{"credential_id" => "admin", "expected_generation" => "0"},
               context.now
             )

    assert {:error, %{"code" => "invalid_request"}} =
             Service.revoke(
               context.service,
               context.admin,
               context.scope,
               Identifier.uuid(),
               %{},
               context.now
             )

    assert {:ok, %{"outcome" => "committed", "generation" => "1"}} =
             Service.revoke(
               context.service,
               context.admin,
               context.scope,
               Identifier.uuid(),
               %{"credential_id" => "reader", "expected_generation" => "0"},
               context.now
             )

    assert {:error, %{"code" => "unauthorized"}} =
             Service.list(
               context.service,
               context.reader,
               context.scope,
               "state",
               %{},
               context.now
             )
  end

  test "exact point reads support historical tombstones and do not mix generations" do
    {store, _} = store()
    assert {:ok, _} = Store.mutate(store, update())
    query = %{scope: "workshop", kind: "state", id: "sensor", generation: "1"}
    assert {:ok, %{"value" => %{"temperature" => 24.3}}} = Store.fetch(store, query)

    assert {:ok, _} =
             Store.mutate(
               store,
               update(%{
                 observation: nil,
                 operation_id: "delete",
                 expected_generation: "1",
                 records: [%{kind: "state", id: "sensor", value: nil}]
               })
             )

    assert {:ok, _} = Store.fetch(store, query)
    assert {:error, :not_found} = Store.fetch(store, %{query | generation: nil})
    assert {:error, :invalid_cursor} = Store.fetch(store, %{query | generation: "3"})
    assert {:error, :invalid_query} = Store.fetch(store, %{})
    assert {:error, :invalid_query} = Store.fetch(store, %{query | generation: "01"})
  end

  test "configuration forbids credential-bearing URLs, fragments, query strings and relative origins",
       context do
    for base <- [
          nil,
          "",
          "relative",
          "file:///private/data",
          "https://user:password@example.test",
          "https://example.test/?secret=x",
          "https://example.test/#fragment",
          "https://example.test/path",
          "http://localhost:0",
          "http://[bad"
        ] do
      assert {:error, :invalid_configuration} =
               Service.new(%{
                 store: context.store,
                 credentials: context.credentials,
                 base_url: base
               })
    end

    assert {:error, :invalid_configuration} = Service.new(%{})

    assert {:ok, service} =
             Service.new(%{
               store: context.store,
               credentials: context.credentials,
               base_url: "https://example.test/"
             })

    assert service.base_url == "https://example.test"
  end
end
