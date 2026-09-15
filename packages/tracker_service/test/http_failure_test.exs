defmodule Wotex.Tracker.HTTPFailureTest do
  @moduledoc false
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  import Wotex.Tracker.Service.Fixtures
  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.{Codec, Identifier, Store}
  alias Wotex.Tracker.Service.HTTP.{Server, Wire}

  setup do
    Application.ensure_all_started(:inets)
    service()
  end

  test "lost commit acknowledgements are 202 unknown and status lookup returns the durable receipt",
       context do
    server = start_supervised!({Server, options(context)})
    {:ok, store} = Server.child(server, :store)

    :sys.replace_state(store, fn state ->
      put_in(state.options.fault, fn
        :after_commit -> :abort
        _ -> :ok
      end)
    end)

    operation = Identifier.uuid()
    body = Codec.encode!(import_request())

    assert {202, %{"data" => %{"outcome" => "unknown", "operation_id" => ^operation}}} =
             request(server, context, :post, "/observations", body, operation)

    assert {200, %{"data" => %{"outcome" => "committed"} = receipt}} =
             request(server, context, :get, "/operations/" <> operation)

    assert {200, %{"data" => ^receipt}} =
             request(server, context, :post, "/observations", body, operation)

    assert {400, %{"error" => %{"outcome" => "not_committed", "operation_id" => nil}}} =
             request(server, context, :post, "/observations", body, "malformed")

    assert {404, _} = request(server, context, :get, "/../../unknown")
  end

  test "unexpected host defects are redacted and never mislabeled as rolled-back mutations",
       context do
    options = Keyword.put(options(context), :clock, fn -> raise "private-secret-marker" end)
    server = start_supervised!({Server, options})
    operation = Identifier.uuid()

    log =
      capture_log(fn ->
        assert {500,
                %{
                  "error" => %{
                    "code" => "internal_error",
                    "outcome" => "unknown",
                    "operation_id" => ^operation
                  }
                }} =
                 request(
                   server,
                   context,
                   :post,
                   "/observations",
                   Codec.encode!(import_request()),
                   operation
                 )
      end)

    assert log =~ "tracker HTTP request failed"
    refute log =~ "private-secret-marker"
    refute log =~ context.admin
  end

  test "store clock checks expiry after queueing and immediately before commit", context do
    clock = :atomics.new(1, [])
    :atomics.put(clock, 1, context.now)
    current = fn -> :atomics.get(clock, 1) end

    advance = fn
      :before_commit ->
        :atomics.put(clock, 1, context.now + 1_000_000_000)
        :ok

      _ ->
        :ok
    end

    {store, _} = store(credentials: context.credentials, clock: current, fault: advance)
    service = %{context.service | store: store}

    assert {:error, %{"code" => "unauthorized", "outcome" => "not_committed"}} =
             Service.submit(
               service,
               context.admin,
               context.scope,
               Identifier.uuid(),
               import_request(),
               context.now
             )

    assert {:ok, %{"items" => [], "generation" => "0"}} = Store.snapshot(store, query())

    assert {:error, %{"code" => "unauthorized"}} =
             Service.list(service, context.admin, context.scope, "state", %{}, context.now)

    {store, _} = store(credentials: context.credentials, clock: fn -> :bad_clock end)
    service = %{context.service | store: store}

    assert {:error, %{"code" => "storage_unavailable"}} =
             Service.list(service, context.admin, context.scope, "state", %{}, context.now)
  end

  test "self-revocation commits its receipt before denying further requests", context do
    server = start_supervised!({Server, options(context)})
    request = Codec.encode!(%{"credential_id" => "admin", "expected_generation" => "0"})

    assert {200, %{"data" => %{"outcome" => "committed", "generation" => "1"}}} =
             request(server, context, :post, "/revocations", request, Identifier.uuid())

    assert {401, %{"error" => %{"code" => "unauthorized"}}} =
             request(server, context, :get, "/state")
  end

  test "wire bounds and duplicate headers fail without reflecting their contents" do
    conn = Plug.Test.conn(:get, "/")

    conn = %{
      conn
      | req_headers: [{"authorization", "private-one"}, {"authorization", "private-two"}]
    }

    assert {:error, %{"code" => "invalid_header"}} = Wire.single_header(conn, "authorization")

    for query <- ["cursor=%GG", "cursor=%FF", String.duplicate("x", 8193)] do
      assert {:error, %{"code" => "invalid_request"}} =
               Wire.parameters(%{conn | query_string: query})
    end

    assert {:error, :invalid_request} = Wire.path(%{conn | path_info: ["%broken"]})
    response = Wire.json(conn, 200, %{"private" => String.duplicate("x", 4_194_305)})
    assert response.status == 503
    assert Codec.decode!(response.resp_body)["error"]["code"] == "response_too_large"
    refute response.resp_body =~ "private"

    for accept <- [
          "application/json;q=bad",
          "application/json;q=2",
          "application/json;q=0.000",
          "not a type"
        ] do
      refute Wire.acceptable?(
               Plug.Conn.put_req_header(conn, "accept", accept),
               "application/json"
             )
    end
  end

  defp options(context),
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

  defp request(server, context, method, path, body \\ nil, operation \\ nil) do
    {:ok, {_, port}} = Server.listener_info(server)
    url = String.to_charlist("http://127.0.0.1:#{port}/api/v1/scopes/workshop" <> path)
    headers = [{~c"authorization", String.to_charlist("Bearer " <> context.admin)}]

    headers =
      if operation,
        do: [{~c"idempotency-key", String.to_charlist(operation)} | headers],
        else: headers

    input = if body, do: {url, headers, ~c"application/json", body}, else: {url, headers}

    {:ok, {{_, status, _}, _, bytes}} =
      :httpc.request(method, input, [timeout: 5000], body_format: :binary)

    {status, Codec.decode!(bytes)}
  end
end
