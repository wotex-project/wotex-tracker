defmodule Wotex.Tracker.Service.ActionInteractionTest do
  use ExUnit.Case, async: true

  import Wotex.Tracker.Service.Fixtures

  alias Wotex.Runtime.{BindingProfile, Result}
  alias Wotex.Tracker.Service

  alias Wotex.Tracker.Service.{
    ActionDispatcher,
    ActionIntent,
    Codec,
    Credentials,
    Identifier,
    PrimitiveSchema,
    Store,
    Update
  }

  alias Wotex.Tracker.Service.HTTP.Server

  defmodule DeviceCredentials do
    @behaviour Wotex.Runtime.Credentials

    @impl true
    def resolve(_security, _form, _context, {owner, credential}) do
      send(owner, {:device_credential, credential})

      case credential do
        :unavailable -> {:error, :unavailable}
        value -> {:ok, value}
      end
    end
  end

  defmodule Transport do
    @behaviour Wotex.Runtime.Transport

    @impl true
    def request(request, execution, {owner, mode}) do
      send(owner, {:action_request, request.operation, request.input, execution.credential})

      case mode do
        :ok ->
          Result.new(request.request_id, request.operation, nil)

        :accepted ->
          Result.new(request.request_id, request.operation, nil, status: :accepted)

        :error ->
          {:error, :connection_lost}

        :block ->
          receive do
            :release -> Result.new(request.request_id, request.operation, nil)
          end
      end
    end

    @impl true
    def subscribe(_, _, _, _), do: {:error, :unsupported}

    @impl true
    def unsubscribe(_, _, _, _), do: :ok
  end

  test "authorized invocation is a caller-scoped durable intent with closed input" do
    c = action_thing()
    operation = Identifier.uuid()
    request = %{"expected_generation" => c.generation, "input" => 5}

    assert {:error, %{"code" => "unsupported", "outcome" => "not_committed"}} =
             Service.invoke_action(
               %{c.service | action_delivery: :unconfigured},
               c.admin,
               c.scope,
               operation,
               c.thing,
               "refresh",
               request,
               c.now
             )

    assert {:ok, receipt} = invoke(c, operation, request)
    assert receipt["outcome"] == "committed"
    assert receipt["disposition"] == "queued"
    assert receipt["generation"] == c.generation
    assert receipt["data"] == %{"action_id" => operation, "status" => "queued"}
    assert {:ok, ^receipt} = invoke(c, operation, request)

    assert {:error, %{"code" => "idempotency_conflict", "outcome" => "not_committed"}} =
             invoke(c, operation, %{request | "input" => 6})

    assert {:ok, status} = status(c, operation)
    assert status["status"] == "queued"
    assert status["physical_effect"] == "not_dispatched"
    refute Map.has_key?(status, "input")

    for {name, invalid, code} <- [
          {"refresh", %{request | "input" => 0}, "invalid_request"},
          {"refresh", %{request | "input" => 11}, "invalid_request"},
          {"refresh", %{request | "input" => 1.0}, "invalid_request"},
          {"refresh", %{request | "expected_generation" => "3"}, "revision_mismatch"},
          {"missing", request, "not_found"}
        ] do
      assert {:error, %{"code" => ^code, "outcome" => "not_committed"}} =
               invoke(c, Identifier.uuid(), invalid, name)
    end

    assert {:error, %{"code" => "forbidden"}} =
             Service.action_status(c.service, c.reader, c.scope, operation, c.now)

    assert {:error, %{"code" => "forbidden", "outcome" => "not_committed"}} =
             Service.invoke_action(
               c.service,
               c.reader,
               c.scope,
               Identifier.uuid(),
               c.thing,
               "refresh",
               request,
               c.now
             )

    for invalid <- [
          %{},
          %{"expected_generation" => c.generation},
          %{"expected_generation" => "bad", "input" => 5},
          %{"expected_generation" => c.generation, "input" => 5, "extra" => true}
        ] do
      assert {:error, %{"code" => "invalid_request", "outcome" => "not_committed"}} =
               invoke(c, Identifier.uuid(), invalid)
    end
  end

  test "Runtime acceptance settles once without claiming a physical effect" do
    c = action_thing()
    operation = Identifier.uuid()
    assert {:ok, _} = invoke(c, operation, request(c))
    dispatcher = start_dispatcher(c, :accepted)

    assert_receive {:device_credential, "private-device-secret"}, 1_000
    assert_receive {:action_request, :invokeaction, 5, "private-device-secret"}, 1_000

    eventually(fn ->
      match?(
        {:ok,
         %{
           "status" => "accepted",
           "outcome" => %{"classification" => "protocol_accepted"},
           "physical_effect" => "unknown"
         }},
        status(c, operation)
      )
    end)

    assert :ok = ActionDispatcher.dispatch(dispatcher)
    refute_receive {:action_request, _, _, _}, 100
    refute inspect(elem(status(c, operation), 1)) =~ "private-device-secret"
  end

  test "transport ambiguity and dispatcher timeout remain unknown without retry" do
    for mode <- [:error, :block] do
      c = action_thing()
      operation = Identifier.uuid()
      assert {:ok, _} = invoke(c, operation, request(c))
      dispatcher = start_dispatcher(c, mode, timeout_ms: 500, interval_ms: 60_000)
      assert_receive {:action_request, :invokeaction, 5, "private-device-secret"}, 2_000

      if mode == :block do
        assert {:error, :busy} = ActionDispatcher.dispatch(dispatcher)
        send(dispatcher, :dispatch)
        send(dispatcher, :unexpected)
      end

      eventually(fn -> match?({:ok, %{"status" => "unknown"}}, status(c, operation)) end)

      eventually(fn ->
        match?(
          {:ok, %{"running" => false}},
          ActionDispatcher.snapshot(dispatcher)
        )
      end)

      assert :ok = ActionDispatcher.dispatch(dispatcher)
      refute_receive {:action_request, _, _, _}, 100
    end
  end

  test "Runtime construction, selection and credential failures are terminal before transport" do
    for {failure, classification} <- [
          {:construction, "runtime_construction"},
          {:selection, "runtime_selection"},
          {:credentials, "runtime_credentials"}
        ] do
      c = action_thing()
      operation = Identifier.uuid()
      assert {:ok, _} = invoke(c, operation, request(c))
      dispatcher = start_dispatcher(c, runtime_failure(failure))

      eventually(fn ->
        match?(
          {:ok,
           %{
             "status" => "failed",
             "outcome" => %{"classification" => ^classification},
             "physical_effect" => "not_dispatched"
           }},
          status(c, operation)
        )
      end)

      assert {:ok, %{"last_result" => %{"failed" => 1}}} =
               eventually_value(fn -> ActionDispatcher.snapshot(dispatcher) end, fn
                 {:ok, %{"running" => false, "last_result" => %{"failed" => 1}}} -> true
                 _ -> false
               end)

      refute_receive {:action_request, _, _, _}, 50
    end
  end

  test "the durable queue validates claims and makes settlement conflict-safe" do
    c = action_thing()
    operation = Identifier.uuid()
    assert {:ok, _} = invoke(c, operation, request(c))

    assert {:error, :invalid_query} = Store.claim_actions(c.store, "", c.now, 1)
    assert {:error, :invalid_query} = Store.claim_actions(c.store, c.scope, c.now, 0)

    assert {:ok, %{"items" => [item], "denied" => 0}} =
             Store.claim_actions(c.store, c.scope, c.now, 1)

    completion = %{status: :accepted, classification: "protocol_ok", at: c.now + 1}

    assert {:ok, %{"status" => "accepted"} = settled} =
             Store.settle_action(
               c.store,
               c.scope,
               item["principal"],
               operation,
               item["intent_identity"],
               completion
             )

    assert settled["physical_effect"] == "unknown"

    assert {:ok, ^settled} =
             Store.settle_action(
               c.store,
               c.scope,
               item["principal"],
               operation,
               item["intent_identity"],
               completion
             )

    assert {:error, :action_conflict} =
             Store.settle_action(
               c.store,
               c.scope,
               item["principal"],
               operation,
               String.duplicate("0", 64),
               completion
             )

    assert {:error, :invalid_query} =
             Store.settle_action(
               c.store,
               c.scope,
               item["principal"],
               operation,
               item["intent_identity"],
               %{completion | classification: "dispatch_unknown"}
             )

    assert {:ok, %{"items" => []}} = Store.claim_actions(c.store, c.scope, c.now + 2, 1)
  end

  test "Action intents and primitive schemas reject forged or approximate execution" do
    c = action_thing()
    {:ok, access} = Service.authorize(c.service, c.admin, c.scope, "interact", c.now)

    input = %{
      scope: c.scope,
      id: Identifier.uuid(),
      thing_id: c.thing,
      thing_generation: c.generation,
      thing_identity: String.duplicate("a", 64),
      name: "refresh",
      input: 5,
      admitted_at: c.now,
      access: access
    }

    assert {:ok, intent} = ActionIntent.new(input)
    assert {:ok, ^intent} = ActionIntent.validate(intent)
    assert {:ok, ^intent} = intent |> ActionIntent.document() |> ActionIntent.restore()
    assert {:error, :action_conflict} = ActionIntent.validate(%{intent | input: 6})
    assert {:error, :invalid_action_intent} = ActionIntent.validate(%{})
    assert {:error, :invalid_action_intent} = ActionIntent.restore(%{})
    assert {:error, :invalid_action_intent} = ActionIntent.new(%{input | name: "bad\nname"})
    assert {:error, :invalid_action_intent} = ActionIntent.new(%{input | thing_identity: "bad"})

    assert {:ok, nil} = PrimitiveSchema.project(nil)
    assert PrimitiveSchema.accepts?(nil, nil)
    refute PrimitiveSchema.accepts?(nil, false)
    assert {:ok, %{"type" => "boolean"}} = PrimitiveSchema.project(%{"type" => "boolean"})
    assert PrimitiveSchema.accepts?(%{"type" => "boolean"}, true)
    refute PrimitiveSchema.accepts?(%{"type" => "boolean"}, 1)

    number = %{
      "type" => "number",
      "minimum" => 1,
      "exclusiveMaximum" => 3,
      "unit" => "m"
    }

    assert PrimitiveSchema.accepts?(number, 2.5)
    refute PrimitiveSchema.accepts?(number, 3)
    refute PrimitiveSchema.accepts?(Map.put(number, "multipleOf", 0.5), 2.5)
    refute PrimitiveSchema.accepts?(%{"type" => "integer", "exclusiveMinimum" => 2}, 2)
    assert PrimitiveSchema.accepts?(%{"type" => "integer", "exclusiveMaximum" => 3}, 2)

    string = %{"type" => "string", "minLength" => 1, "maxLength" => 2}
    assert PrimitiveSchema.accepts?(string, "å")
    refute PrimitiveSchema.accepts?(string, "")
    refute PrimitiveSchema.accepts?(string, <<255>>)
    refute PrimitiveSchema.accepts?(Map.put(string, "pattern", "^a"), "a")
    assert {:error, :unsupported} = PrimitiveSchema.project(%{"type" => "object"})

    assert {:error, :unsupported} =
             PrimitiveSchema.project(%{"type" => "string", "minLength" => -1})

    assert {:error, :unsupported} = PrimitiveSchema.project(%{"type" => "number", "unit" => ""})
  end

  test "the dispatcher is bounded, supervised and redacts its state" do
    c = service()
    valid = [store: c.store, credentials: c.credentials, runtime: runtime(:ok)]

    for options <- [
          [],
          valid ++ [unknown: true],
          Keyword.put(valid, :store, :invalid),
          Keyword.put(valid, :runtime, %{}),
          Keyword.put(valid, :scopes, ["z", "a"]),
          Keyword.put(valid, :max_batch, 0),
          Keyword.put(valid, :interval_ms, 0),
          Keyword.put(valid, :timeout_ms, 0),
          Keyword.put(valid, :clock, :invalid),
          Keyword.put(valid, :monotonic_clock, :invalid)
        ] do
      assert {:error, :invalid_options} = ActionDispatcher.start_link(options)
    end

    default_dispatcher =
      start_supervised!({ActionDispatcher, valid}, id: make_ref())

    eventually(fn ->
      match?(
        {:ok, %{"running" => false, "last_result" => %{"claimed" => 0, "failed" => 0}}},
        ActionDispatcher.snapshot(default_dispatcher)
      )
    end)

    {:ok, supervisor} = Supervisor.start_link([], strategy: :one_for_one)

    dispatcher =
      start_supervised!(
        {ActionDispatcher,
         store: {:supervisor, supervisor},
         credentials: c.credentials,
         runtime: runtime(:ok),
         interval_ms: 60_000},
        id: make_ref()
      )

    eventually(fn ->
      match?(
        {:ok, %{"running" => false, "last_result" => %{"failed" => 1}}},
        ActionDispatcher.snapshot(dispatcher)
      )
    end)

    status_text = :sys.get_status(dispatcher) |> inspect()
    refute status_text =~ c.admin
    refute status_text =~ "private-device-secret"
    GenServer.stop(dispatcher)
    assert {:error, :storage_unavailable} = ActionDispatcher.snapshot(dispatcher)
  end

  test "dispatcher cycle failures are contained without retrying claimed work" do
    for failing_clock <- [
          fn -> raise "private clock failure" end,
          fn -> exit(:private_clock_failure) end,
          fn -> throw(:private_clock_failure) end
        ] do
      c = service()
      dispatcher = start_dispatcher(c, :ok, clock: failing_clock)

      eventually(fn ->
        match?(
          {:ok, %{"running" => false, "last_result" => %{"failed" => 1}}},
          ActionDispatcher.snapshot(dispatcher)
        )
      end)
    end

    claim = service()
    GenServer.stop(claim.store.pid)

    {claim_store, _} =
      store(
        directory: claim.directory,
        credentials: claim.credentials,
        fault: fn phase -> if phase == :action_claim_before_commit, do: :abort, else: :ok end
      )

    claim_dispatcher = start_dispatcher(%{claim | store: claim_store}, :ok)

    eventually(fn ->
      match?(
        {:ok, %{"running" => false, "last_result" => %{"failed" => 1}}},
        ActionDispatcher.snapshot(claim_dispatcher)
      )
    end)

    settle = action_thing()
    operation = Identifier.uuid()
    assert {:ok, _} = invoke(settle, operation, request(settle))
    GenServer.stop(settle.store.pid)

    {settle_store, _} =
      store(
        directory: settle.directory,
        credentials: settle.credentials,
        fault: fn phase -> if phase == :action_settle_before_commit, do: :abort, else: :ok end
      )

    settle = %{
      settle
      | store: settle_store,
        service: %{settle.service | store: settle_store}
    }

    settle_dispatcher = start_dispatcher(settle, :ok)
    assert_receive {:action_request, :invokeaction, 5, "private-device-secret"}, 1_000

    eventually(fn ->
      match?(
        {:ok, %{"running" => false, "last_result" => %{"failed" => 1}}},
        ActionDispatcher.snapshot(settle_dispatcher)
      )
    end)

    assert {:ok, %{"status" => "unknown"}} = status(settle, operation)

    {:ok, stopped_supervisor} = Supervisor.start_link([], strategy: :one_for_one)
    Supervisor.stop(stopped_supervisor)

    unavailable =
      start_supervised!(
        {ActionDispatcher,
         store: {:supervisor, stopped_supervisor},
         credentials: settle.credentials,
         runtime: runtime(:ok),
         interval_ms: 60_000},
        id: make_ref()
      )

    eventually(fn ->
      match?(
        {:ok, %{"running" => false, "last_result" => %{"failed" => 1}}},
        ActionDispatcher.snapshot(unavailable)
      )
    end)
  end

  test "a changed Thing revision is denied before Runtime receives the intent" do
    c = action_thing()
    operation = Identifier.uuid()
    assert {:ok, _} = invoke(c, operation, request(c))
    c = revise_thing(c)
    assert {:ok, %{"disposition" => "queued"}} = invoke(c, operation, request(c))
    _dispatcher = start_dispatcher(c, :ok)

    eventually(fn -> match?({:ok, %{"status" => "denied"}}, status(c, operation)) end)
    refute_receive {:action_request, _, _, _}, 100
  end

  test "dispatch-time durable revocation denies the intent before Runtime" do
    c = action_thing() |> add_reviewer()
    operation = Identifier.uuid()
    assert {:ok, _} = invoke(c, operation, request(c))

    assert {:ok, %{"generation" => "5"}} =
             Service.revoke(
               c.service,
               c.reviewer,
               c.scope,
               Identifier.uuid(),
               %{"credential_id" => "admin", "expected_generation" => "4"},
               c.now
             )

    _dispatcher = start_dispatcher(c, :ok)

    eventually(fn ->
      match?(
        {:ok, %{"status" => "denied", "physical_effect" => "not_dispatched"}},
        Service.action_status(c.service, c.reviewer, c.scope, operation, c.now)
      )
    end)

    refute_receive {:action_request, _, _, _}, 100
  end

  test "Action admission reports pre-commit failure and retained post-commit uncertainty" do
    before = action_thing(fault: &fault(&1, :action_before_commit))
    operation = Identifier.uuid()

    assert {:error, %{"code" => "storage_unavailable", "outcome" => "not_committed"}} =
             invoke(before, operation, request(before))

    assert {:error, %{"code" => "not_found"}} = status(before, operation)

    after_commit = action_thing(fault: &fault(&1, :action_after_commit))
    operation = Identifier.uuid()

    assert {:ok, %{"outcome" => "unknown", "operation_id" => ^operation}} =
             invoke(after_commit, operation, request(after_commit))

    assert {:ok, %{"status" => "queued"}} = status(after_commit, operation)
  end

  test "the versioned HTTP boundary queues and polls an Action through the supervised Runtime" do
    c = action_thing()
    server = start_supervised!({Server, server_options(c, runtime(:ok))})
    operation = Identifier.uuid()
    thing = URI.encode(c.thing, &URI.char_unreserved?/1)

    assert {200,
            %{
              "schema" => "wtr.response.v1",
              "data" => %{"operation_id" => ^operation, "disposition" => "queued"}
            }} =
             http(
               server,
               c,
               :post,
               "/things/#{thing}/actions/refresh",
               %{"expected_generation" => c.generation, "input" => 5},
               operation
             )

    assert {:ok, dispatcher} = Server.child(server, :action_dispatcher)
    assert :ok = ActionDispatcher.dispatch(dispatcher)
    assert_receive {:action_request, :invokeaction, 5, "private-device-secret"}, 1_000

    eventually(fn ->
      match?(
        {200,
         %{
           "data" => %{
             "operation_id" => ^operation,
             "status" => "accepted",
             "physical_effect" => "unknown"
           }
         }},
        http(server, c, :get, "/actions/#{operation}")
      )
    end)

    assert {200, %{"data" => %{"runtime" => %{"invokeaction" => "configured"}}}} =
             http(server, c, :get, "/capabilities")

    contract = File.read!(Application.app_dir(:wotex_tracker_service, "priv/openapi/v1.json"))
    assert contract =~ "/things/{id}/actions/{action}"
    assert contract =~ "/actions/{operation}"
  end

  defp action_thing(options \\ []) do
    c = service(options)
    {thing, _} = materialized(c)
    {:ok, access} = Service.authorize(c.service, c.admin, c.scope, "enroll", c.now)

    {:ok, row} =
      Store.fetch(c.store, %{scope: c.scope, kind: "things", id: thing, generation: nil})

    action = %{
      "input" => %{"type" => "integer", "minimum" => 1, "maximum" => 10},
      "forms" => [
        %{
          "href" => "https://device.invalid/actions/refresh",
          "op" => ["invokeaction"],
          "contentType" => "application/json"
        }
      ]
    }

    td = Map.put(row["value"]["public"], "actions", %{"refresh" => action})
    assert {:ok, _} = Wotex.ThingDescription.from_map(td)
    value = Map.put(row["value"], "public", td)

    {:ok, update} =
      Update.new(%{
        principal: access.principal,
        scope: c.scope,
        authority: access,
        operation_id: Identifier.uuid(),
        expected_generation: "3",
        request: %{"operation" => "install_action_fixture", "thing_id" => thing},
        now: c.now,
        observation: nil,
        records: [%{kind: "things", id: thing, value: value}],
        events: [%{"type" => "thing.changed", "data" => %{"id" => thing}}],
        publication: nil
      })

    assert {:ok, %{"generation" => "4"}} = Store.mutate(c.store, update)

    Map.merge(c, %{
      service: %{c.service | action_delivery: :configured},
      thing: thing,
      generation: "4"
    })
  end

  defp revise_thing(c) do
    {:ok, access} = Service.authorize(c.service, c.admin, c.scope, "enroll", c.now)

    {:ok, row} =
      Store.fetch(c.store, %{scope: c.scope, kind: "things", id: c.thing, generation: nil})

    {:ok, update} =
      Update.new(%{
        principal: access.principal,
        scope: c.scope,
        authority: access,
        operation_id: Identifier.uuid(),
        expected_generation: "4",
        request: %{"operation" => "revise_action_fixture", "thing_id" => c.thing},
        now: c.now,
        observation: nil,
        records: [
          %{
            kind: "things",
            id: c.thing,
            value: put_in(row["value"], ["public", "title"], "Revised Thing")
          }
        ],
        events: [%{"type" => "thing.changed", "data" => %{"id" => c.thing}}],
        publication: nil
      })

    assert {:ok, %{"generation" => "5"}} = Store.mutate(c.store, update)
    c
  end

  defp add_reviewer(c) do
    reviewer = Credentials.generate_token()
    {:ok, digest} = Credentials.token_digest(reviewer)
    input = Map.from_struct(c.credentials)

    entry = %{
      id: "reviewer",
      principal: "owner",
      token_sha256: digest,
      grants: %{c.scope => ~w(read enroll admin interact)},
      expires_at: c.now + 1_000_000_000
    }

    {:ok, credentials} = Credentials.new(%{input | entries: input.entries ++ [entry]})
    GenServer.stop(c.store.pid)
    {store, _} = store(directory: c.directory, credentials: credentials)

    {:ok, service} =
      Service.new(%{store: store, credentials: credentials, base_url: c.service.base_url})

    Map.merge(c, %{
      store: store,
      credentials: credentials,
      reviewer: reviewer,
      service: %{service | action_delivery: :configured}
    })
  end

  defp invoke(c, operation, request, name \\ "refresh"),
    do:
      Service.invoke_action(
        c.service,
        c.admin,
        c.scope,
        operation,
        c.thing,
        name,
        request,
        c.now
      )

  defp status(c, operation),
    do: Service.action_status(c.service, c.admin, c.scope, operation, c.now)

  defp request(c), do: %{"expected_generation" => c.generation, "input" => 5}

  defp start_dispatcher(c, mode, options \\ []) do
    runtime = if is_map(mode), do: mode, else: runtime(mode)

    start_supervised!(
      {ActionDispatcher,
       Keyword.merge(
         [
           store: c.store,
           credentials: c.credentials,
           runtime: runtime,
           scopes: [c.scope],
           clock: fn -> c.now end,
           interval_ms: 60_000
         ],
         options
       )},
      id: make_ref()
    )
  end

  defp runtime(mode) do
    profile = profile(["https"])

    %{
      profiles: [profile],
      transports: %{action: {Transport, {self(), mode}}},
      credentials: {DeviceCredentials, {self(), "private-device-secret"}}
    }
  end

  defp runtime_failure(:construction),
    do: %{
      profiles: [profile(["https"])],
      transports: %{},
      credentials: {DeviceCredentials, {self(), "private-device-secret"}}
    }

  defp runtime_failure(:selection),
    do: %{
      profiles: [profile(["coap"])],
      transports: %{action: {Transport, {self(), :ok}}},
      credentials: {DeviceCredentials, {self(), "private-device-secret"}}
    }

  defp runtime_failure(:credentials),
    do: %{
      profiles: [profile(["https"])],
      transports: %{action: {Transport, {self(), :ok}}},
      credentials: {DeviceCredentials, {self(), :unavailable}}
    }

  defp profile(schemes) do
    {:ok, profile} =
      BindingProfile.new(
        id: :action,
        schemes: schemes,
        operations: [:invokeaction],
        media_types: ["application/json"]
      )

    profile
  end

  defp server_options(c, runtime),
    do: [
      directory: c.directory,
      credentials: c.credentials,
      ip: {127, 0, 0, 1},
      port: 0,
      public_origin: :listener,
      exposure: :loopback,
      clock: fn -> c.now end,
      action_dispatcher: [
        runtime: runtime,
        scopes: [c.scope],
        interval_ms: 60_000,
        timeout_ms: 1_000
      ]
    ]

  defp http(server, c, method, path, body \\ nil, operation \\ nil) do
    {:ok, {_, port}} = Server.listener_info(server)
    url = String.to_charlist("http://127.0.0.1:#{port}/api/v1/scopes/#{c.scope}" <> path)
    headers = [{~c"authorization", String.to_charlist("Bearer " <> c.admin)}]

    headers =
      if operation,
        do: [{~c"idempotency-key", String.to_charlist(operation)} | headers],
        else: headers

    input =
      if body,
        do: {url, headers, ~c"application/json", Codec.encode!(body)},
        else: {url, headers}

    {:ok, {{_, status, _}, _, bytes}} =
      :httpc.request(method, input, [timeout: 5_000], body_format: :binary)

    {status, Codec.decode!(bytes)}
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually_value(fun, predicate, attempts \\ 100)
  defp eventually_value(fun, _predicate, 0), do: fun.()

  defp eventually_value(fun, predicate, attempts) do
    value = fun.()

    if predicate.(value) do
      value
    else
      Process.sleep(10)
      eventually_value(fun, predicate, attempts - 1)
    end
  end

  defp fault(phase, phase), do: :abort
  defp fault(_, _), do: :ok
end
