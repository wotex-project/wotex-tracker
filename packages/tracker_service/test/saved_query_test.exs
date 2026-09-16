defmodule Wotex.Tracker.Service.SavedQueryTest do
  use ExUnit.Case, async: true

  import Wotex.Tracker.Service.Fixtures

  alias Wotex.Tracker.QuerySpec
  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.{Codec, Credentials, Identifier, Projection, Store, Update}
  alias Wotex.Tracker.Service.HTTP.Server

  setup do
    service()
  end

  test "saved queries retain ownership, versions, events and deletion tombstones", context do
    {:ok, initial} =
      Service.list(
        context.service,
        context.reader,
        context.scope,
        "saved_queries",
        %{},
        context.now
      )

    request = save_request(query_document(context.now), "0")
    operation = Identifier.uuid()

    assert {:ok, saved} =
             Service.save_query(
               context.service,
               context.admin,
               context.scope,
               operation,
               request,
               context.now
             )

    assert saved["generation"] == "1"
    assert saved["data"] == %{"query_id" => "workshop-temperature"}

    assert {:ok, ^saved} =
             Service.save_query(
               context.service,
               context.admin,
               context.scope,
               operation,
               request,
               context.now
             )

    assert {:ok, %{"value" => definition}} =
             Service.get(
               context.service,
               context.reader,
               context.scope,
               "saved_queries",
               "workshop-temperature",
               context.now
             )

    assert definition["schema"] == "wtr.saved-query.v1"
    assert definition["window"] == "absolute"
    assert definition["owner"] =~ "wtr1_"
    refute definition["owner"] == "owner"
    assert definition["created_at"] == context.now
    assert definition["updated_at"] == context.now

    changed =
      request
      |> Map.put("title", "Temperature incident")
      |> Map.put("visualization", %{
        "type" => "points",
        "show_legend" => false,
        "show_points" => true
      })
      |> Map.put("expected_generation", "1")

    assert {:ok, %{"generation" => "2"}} =
             Service.save_query(
               context.service,
               context.admin,
               context.scope,
               Identifier.uuid(),
               changed,
               context.now + 1
             )

    assert {:ok, %{"items" => [item]}} =
             Service.list(
               context.service,
               context.reader,
               context.scope,
               "saved_queries",
               %{},
               context.now + 1
             )

    assert item["value"]["title"] == "Temperature incident"
    assert item["value"]["created_at"] == context.now
    assert item["value"]["updated_at"] == context.now + 1

    assert {:ok, %{"items" => [first, second]}} =
             Service.history(
               context.service,
               context.reader,
               context.scope,
               "saved_queries",
               "workshop-temperature",
               %{},
               context.now + 1
             )

    refute first["deleted"]
    refute second["deleted"]
    assert first["value"]["title"] == "Workshop temperature"
    assert second["value"]["title"] == "Temperature incident"

    assert {:ok, events} =
             Service.events(
               context.service,
               context.reader,
               context.scope,
               initial["stream_cursor"],
               context.now + 1
             )

    assert Enum.map(events["items"], &get_in(&1, ["event", "data", "action"])) == [
             "saved",
             "saved"
           ]

    delete = %{"id" => "workshop-temperature", "expected_generation" => "2"}

    assert {:ok, %{"generation" => "3"}} =
             Service.delete_query(
               context.service,
               context.admin,
               context.scope,
               Identifier.uuid(),
               delete,
               context.now + 2
             )

    assert {:error, %{"code" => "not_found"}} =
             Service.get(
               context.service,
               context.reader,
               context.scope,
               "saved_queries",
               "workshop-temperature",
               context.now + 2
             )

    assert {:ok, %{"items" => [_, _, tombstone]}} =
             Service.history(
               context.service,
               context.reader,
               context.scope,
               "saved_queries",
               "workshop-temperature",
               %{},
               context.now + 2
             )

    assert tombstone["deleted"]
    assert tombstone["value"] == nil
  end

  test "save admission, authority and generation checks fail closed", context do
    request = save_request(query_document(context.now), "0")

    assert {:error, %{"code" => "forbidden"}} =
             Service.save_query(
               context.service,
               context.reader,
               context.scope,
               Identifier.uuid(),
               request,
               context.now
             )

    for invalid <- [
          Map.put(request, "extra", true),
          put_in(request, ["query", "identity"], "forged"),
          put_in(request, ["visualization", "type"], "script"),
          put_in(request, ["visualization", "extra"], true),
          Map.put(request, "expected_generation", "00")
        ] do
      assert {:error, %{"code" => "invalid_request"}} =
               Service.save_query(
                 context.service,
                 context.admin,
                 context.scope,
                 Identifier.uuid(),
                 invalid,
                 context.now
               )
    end

    assert {:error, %{"code" => "invalid_request"}} =
             Service.save_query(
               context.service,
               context.admin,
               context.scope,
               "not-an-operation",
               request,
               context.now
             )

    assert {:ok, _} =
             Service.save_query(
               context.service,
               context.admin,
               context.scope,
               Identifier.uuid(),
               request,
               context.now
             )

    assert {:error, %{"code" => "conflict", "outcome" => "not_committed"}} =
             Service.save_query(
               context.service,
               context.admin,
               context.scope,
               Identifier.uuid(),
               request,
               context.now
             )

    assert {:error, %{"code" => "not_found"}} =
             Service.delete_query(
               context.service,
               context.admin,
               context.scope,
               Identifier.uuid(),
               %{"id" => "missing", "expected_generation" => "1"},
               context.now
             )

    other = Credentials.generate_token()
    {:ok, owner_digest} = Credentials.token_digest(context.admin)
    {:ok, other_digest} = Credentials.token_digest(other)

    {:ok, credentials} =
      Credentials.new(%{
        instance_id: "saved-query-owners",
        secret_key: :crypto.strong_rand_bytes(32),
        entries: [
          %{
            id: "owner",
            principal: "owner",
            token_sha256: owner_digest,
            grants: %{context.scope => ~w(read admin)},
            expires_at: context.now + 1_000
          },
          %{
            id: "other",
            principal: "other-owner",
            token_sha256: other_digest,
            grants: %{context.scope => ~w(read admin)},
            expires_at: context.now + 1_000
          }
        ]
      })

    GenServer.stop(context.store.pid)
    {store, _} = store(directory: context.directory, credentials: credentials)
    service = %{context.service | store: store, credentials: credentials}

    assert {:error, %{"code" => "forbidden"}} =
             Service.save_query(
               service,
               other,
               context.scope,
               Identifier.uuid(),
               %{request | "expected_generation" => "1"},
               context.now
             )

    assert {:error, %{"code" => "forbidden"}} =
             Service.delete_query(
               service,
               other,
               context.scope,
               Identifier.uuid(),
               %{"id" => request["id"], "expected_generation" => "1"},
               context.now
             )
  end

  test "executing a saved definition reauthorizes and uses the deterministic query engine",
       context do
    put_state(context, "sensor", context.now, 12.5)
    request = save_request(query_document(context.now), "1")

    assert {:ok, _} =
             Service.save_query(
               context.service,
               context.admin,
               context.scope,
               Identifier.uuid(),
               request,
               context.now
             )

    assert {:ok, result} =
             Service.execute_saved_query(
               context.service,
               context.reader,
               context.scope,
               "workshop-temperature",
               context.now
             )

    assert result["spec"] == request["query"]
    assert get_in(result, ["series", Access.at(0), "points", Access.at(0), "value"]) === 12.5

    assert {:error, %{"code" => "forbidden"}} =
             Service.execute_saved_query(
               context.service,
               context.reader,
               "other",
               "workshop-temperature",
               context.now
             )
  end

  test "HTTP exposes saved definitions and executes them without another model step", context do
    Application.ensure_all_started(:inets)
    server = start_supervised!({Server, server_options(context)})
    request = save_request(query_document(context.now), "0")
    operation = Identifier.uuid()

    assert {200, %{"data" => %{"data" => %{"query_id" => "workshop-temperature"}}}} =
             http(
               server,
               context,
               :post,
               "/saved_queries",
               Codec.encode!(request),
               operation
             )

    assert {200, %{"data" => %{"items" => [%{"value" => definition}]}}} =
             http(server, context, :get, "/saved_queries")

    assert definition["query"] == request["query"]

    assert {200, %{"data" => result}} =
             http(server, context, :get, "/saved_queries/workshop-temperature/execute")

    assert result["spec"] == request["query"]

    assert result["series"] == [
             %{
               "schema" => "wtr.query-series.v1",
               "id" => "sensor",
               "unit" => "Cel",
               "points" => []
             }
           ]
  end

  defp save_request(query, generation) do
    %{
      "id" => "workshop-temperature",
      "title" => "Workshop temperature",
      "query" => query,
      "visualization" => %{
        "type" => "line",
        "show_legend" => true,
        "show_points" => false
      },
      "expected_generation" => generation
    }
  end

  defp query_document(now) do
    {:ok, spec} =
      QuerySpec.new(%{
        id: "temperature-history",
        revision: "saved-query-v1",
        dataset: :measurements,
        measurement: "temperature",
        unit: "Cel",
        series: ["sensor"],
        qualities: [:valid],
        from_at: now,
        to_at: now + 1_000,
        timezone: "Etc/UTC",
        bucket_ms: 1_000,
        aggregation: :mean,
        order: :ascending,
        max_points: 1
      })

    {:ok, document} = QuerySpec.to_map(spec)
    document
  end

  defp put_state(context, id, event_at, value) do
    {:ok, access} =
      Service.authorize(context.service, context.admin, context.scope, "ingest", context.now)

    {:ok, update} =
      Update.new(%{
        principal: access.principal,
        scope: context.scope,
        authority: access,
        operation_id: Identifier.uuid(),
        expected_generation: "0",
        request: %{"operation" => "state-fixture"},
        now: context.now,
        observation: nil,
        records: [
          %{
            kind: "state",
            id: id,
            value: %{
              "public" => %{
                "id" => id,
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

    assert {:ok, _} = Store.mutate(context.store, update)
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
      poll_interval: 25
    ]

  defp http(server, context, method, path, body \\ nil, operation \\ nil) do
    {:ok, {_, port}} = Server.listener_info(server)
    url = String.to_charlist("http://127.0.0.1:#{port}/api/v1/scopes/workshop" <> path)
    headers = [{~c"authorization", String.to_charlist("Bearer " <> context.admin)}]

    headers =
      if operation,
        do: [{~c"idempotency-key", String.to_charlist(operation)} | headers],
        else: headers

    input = if body, do: {url, headers, ~c"application/json", body}, else: {url, headers}

    {:ok, {{_, status, _}, _, bytes}} =
      :httpc.request(method, input, [timeout: 5_000], body_format: :binary)

    {status, Codec.decode!(bytes)}
  end
end
