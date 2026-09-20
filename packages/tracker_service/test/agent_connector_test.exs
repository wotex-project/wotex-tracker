defmodule Wotex.Tracker.Service.AgentConnectorTest do
  use ExUnit.Case, async: true

  import Wotex.Tracker.Service.Fixtures

  alias Wotex.Tracker.Service.{
    AgentConnector,
    AgentConnectorConfig,
    AgentProjection,
    Identifier
  }

  defmodule Peer do
    @behaviour Wotex.Tracker.Service.AgentAdapter

    @impl true
    def investigate(%{behavior: behavior, owner: owner}, config, request, emit) do
      send(owner, {:provider_request, self(), request, inspect(config), config.authorization})
      perform(behavior, owner, request, emit)
    end

    defp perform(:success, _owner, request, emit) do
      :ok = emit.(event(request, 0, "cold "))
      :ok = emit.(event(request, 1, "chain"))
      {:ok, result(request, "completed", [])}
    end

    defp perform(:block, owner, request, _emit) do
      send(owner, {:provider_blocked, self(), request["request_id"]})

      receive do
        {:return, value} -> value
      end
    end

    defp perform(:raise, _owner, _request, _emit), do: raise("synthetic provider failure")
    defp perform(:throw, _owner, _request, _emit), do: throw(:synthetic_provider_failure)
    defp perform(:kill, _owner, _request, _emit), do: Process.exit(self(), :kill)
    defp perform(:invalid_return, _owner, _request, _emit), do: :invalid
    defp perform(:reject, _owner, _request, _emit), do: {:error, :rejected}
    defp perform(:unavailable, _owner, _request, _emit), do: {:error, :unavailable}

    defp perform(:invalid_event, _owner, request, emit) do
      emit.(event(request, 1, "out of order"))
      {:ok, result(request, "completed", [])}
    end

    defp perform(:malformed_event, _owner, request, emit) do
      emit.(%{"schema" => "open"})
      {:ok, result(request, "completed", [])}
    end

    defp perform(:wrong_request_id, _owner, request, emit) do
      request
      |> event(0, "wrong request")
      |> Map.put("request_id", Identifier.uuid())
      |> emit.()

      {:ok, result(request, "completed", [])}
    end

    defp perform(:oversize, _owner, request, emit) do
      emit.(event(request, 0, String.duplicate("x", 512)))
      {:ok, result(request, "completed", [])}
    end

    defp event(request, sequence, text),
      do: %{
        "schema" => "wtr.agent-stream-event.v1",
        "request_id" => request["request_id"],
        "sequence" => sequence,
        "kind" => "text_delta",
        "text" => text
      }

    defp result(request, finish_reason, proposals),
      do: %{
        "schema" => "wtr.agent-provider-result.v1",
        "request_id" => request["request_id"],
        "finish_reason" => finish_reason,
        "proposals" => proposals
      }
  end

  test "disabled configuration starts no process and enabled absence is non-blocking" do
    assert :ignore =
             AgentConnector.start_link(
               config: %{"schema" => "wtr.agent-connector.v1", "enabled" => false}
             )

    connector = connector(adapter: nil)

    assert {:ok,
            %{
              "schema" => "wtr.agent-connector-status.v1",
              "enabled" => true,
              "availability" => "unavailable",
              "provider" => "synthetic",
              "active" => 0,
              "capacity" => 2
            }} = AgentConnector.status(connector)

    context = service()
    {thing, _td} = materialized(context)

    assert {:error, :unavailable} =
             AgentConnector.investigate(
               connector,
               context.service,
               context.reader,
               context.scope,
               request(thing, "3"),
               context.now
             )

    assert Process.alive?(connector)
  end

  test "authorized projection reaches a synthetic peer through a bounded redacted contract" do
    context = service()
    {thing, _td} = materialized(context)
    connector = connector(adapter: {Peer, %{owner: self(), behavior: :success}})
    investigation = request(thing, "3")

    assert {:ok, response} =
             AgentConnector.investigate(
               connector,
               context.service,
               context.reader,
               context.scope,
               investigation,
               context.now
             )

    assert response == %{
             "schema" => "wtr.agent-investigation.v1",
             "request_id" => investigation["request_id"],
             "thing" => %{"id" => thing, "generation" => "3"},
             "finish_reason" => "completed",
             "answer" => "cold chain",
             "proposals" => []
           }

    assert_receive {:provider_request, _worker, provider_request, inspected, authorization}
    assert provider_request["schema"] == "wtr.agent-provider-request.v1"
    assert provider_request["prompt"] == "Assess the disclosed readings"
    assert provider_request["tools"]["thing"] == %{"id" => thing, "generation" => "3"}
    assert authorization == "Bearer private-provider-token"
    refute inspected =~ "private-provider-token"

    encoded = Jason.encode!(provider_request)
    refute encoded =~ context.reader
    refute encoded =~ "forms"
    refute encoded =~ "href"
    refute encoded =~ "observation-1"

    assert {:ok, %{"active" => 0, "availability" => "available"}} =
             AgentConnector.status(connector)

    refute inspect(:sys.get_state(connector)) =~ "private-provider-token"
  end

  test "authority, disclosure and current generation fail before a provider call" do
    context = service()
    {thing, _td} = materialized(context)
    connector = connector(adapter: {Peer, %{owner: self(), behavior: :success}})

    assert {:error, %{"code" => "unauthorized"}} =
             AgentConnector.investigate(
               connector,
               context.service,
               "invalid",
               context.scope,
               request(thing, "3"),
               context.now
             )

    assert {:error, %{"code" => "revision_mismatch"}} =
             AgentConnector.investigate(
               connector,
               context.service,
               context.reader,
               context.scope,
               request(thing, "2"),
               context.now
             )

    assert {:error, :invalid_request} =
             AgentConnector.investigate(
               connector,
               context.service,
               context.reader,
               context.scope,
               Map.put(request(thing, "3"), "extra", true),
               context.now
             )

    refute_receive {:provider_request, _, _, _, _}
  end

  test "explicit cancellation and caller death terminate the provider stream" do
    context = service()
    {thing, _td} = materialized(context)
    connector = connector(adapter: {Peer, %{owner: self(), behavior: :block}})
    investigation = request(thing, "3")

    task =
      Task.async(fn ->
        AgentConnector.investigate(
          connector,
          context.service,
          context.reader,
          context.scope,
          investigation,
          context.now
        )
      end)

    assert_receive {:provider_request, worker, _, _, _}
    assert_receive {:provider_blocked, ^worker, request_id}
    worker_monitor = Process.monitor(worker)
    assert :ok = AgentConnector.cancel(connector, request_id)
    assert {:error, :cancelled} = Task.await(task)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}

    caller =
      spawn(fn ->
        AgentConnector.investigate(
          connector,
          context.service,
          context.reader,
          context.scope,
          request(thing, "3"),
          context.now
        )
      end)

    assert_receive {:provider_request, second_worker, _, _, _}
    assert_receive {:provider_blocked, ^second_worker, _}
    second_monitor = Process.monitor(second_worker)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^second_monitor, :process, ^second_worker, :killed}
    eventually(fn -> match?({:ok, %{"active" => 0}}, AgentConnector.status(connector)) end)
  end

  test "deadline, capacity, crashes and malformed streams fail without stopping the connector" do
    context = service()
    {thing, _td} = materialized(context)

    blocked =
      connector(
        adapter: {Peer, %{owner: self(), behavior: :block}},
        config: config(%{"timeout_ms" => 100, "max_concurrency" => 1})
      )

    first = Task.async(fn -> investigate(blocked, context, request(thing, "3")) end)
    assert_receive {:provider_request, worker, _, _, _}
    assert_receive {:provider_blocked, ^worker, active_request_id}

    duplicate = request(thing, "3")
    duplicate = %{duplicate | "request_id" => active_request_id}
    assert {:error, :conflict} = investigate(blocked, context, duplicate)
    assert {:error, :overloaded} = investigate(blocked, context, request(thing, "3"))
    assert {:error, :deadline_exceeded} = Task.await(first)
    assert Process.alive?(blocked)

    for {behavior, expected} <- [
          {:raise, {:error, :unavailable}},
          {:throw, {:error, :unavailable}},
          {:kill, {:error, :unavailable}},
          {:invalid_return, {:error, :unavailable}},
          {:reject, {:error, :forbidden}},
          {:unavailable, {:error, :unavailable}},
          {:invalid_event, {:error, :unavailable}},
          {:malformed_event, {:error, :unavailable}},
          {:wrong_request_id, {:error, :unavailable}},
          {:oversize, {:error, :response_too_large}}
        ] do
      connector =
        connector(
          adapter: {Peer, %{owner: self(), behavior: behavior}},
          config: config(%{"max_response_bytes" => 256})
        )

      assert ^expected = investigate(connector, context, request(thing, "3"))
      assert Process.alive?(connector)
    end
  end

  test "primitive proposal arguments are validated before policy disposition" do
    request_id = Identifier.uuid()

    for {schema, admitted} <- [
          {nil, nil},
          {%{"type" => "boolean"}, true},
          {%{"type" => "integer", "minimum" => 0, "maximum" => 10}, 3},
          {%{"type" => "number", "multipleOf" => 0.25}, 1.5},
          {%{"type" => "string", "minLength" => 2, "maxLength" => 4}, "bike"}
        ] do
      projection = proposal_projection(schema)
      [tool] = projection["tools"]
      result = provider_result(request_id, [%{"tool_id" => tool["id"], "arguments" => admitted}])

      assert {:ok, %{"proposals" => [%{"disposition" => "denied"}]}} =
               AgentConnector.finalize(projection, request_id, [], result, [], 4096)
    end

    for {schema, rejected} <- [
          {%{"type" => "boolean"}, "true"},
          {%{"type" => "integer", "minimum" => 0}, -1},
          {%{"type" => "number", "multipleOf" => 0.25}, 1.4},
          {%{"type" => "string", "minLength" => 2, "maxLength" => 4}, "x"},
          {%{"type" => "string", "pattern" => "^[a-z]+$"}, "bike"},
          {%{"type" => "object"}, %{}}
        ] do
      projection = proposal_projection(schema)
      [tool] = projection["tools"]
      result = provider_result(request_id, [%{"tool_id" => tool["id"], "arguments" => rejected}])

      assert {:error, :unavailable} =
               AgentConnector.finalize(projection, request_id, [], result, [], 4096)
    end

    projection = proposal_projection(nil)
    malformed = provider_result(request_id, [%{}])

    assert {:error, :unavailable} =
             AgentConnector.finalize(projection, request_id, [], malformed, [], 4096)

    assert {:error, :unavailable} = AgentConnector.finalize(nil, request_id, [], %{}, [], 4096)

    assert {:error, :unavailable} =
             AgentConnector.finalize(
               projection,
               request_id,
               [<<255>>],
               provider_result(request_id, []),
               [],
               4096
             )
  end

  test "dead connectors and stale control messages fail closed" do
    dead = spawn(fn -> :ok end)
    monitor = Process.monitor(dead)
    assert_receive {:DOWN, ^monitor, :process, ^dead, _}

    assert {:error, :unavailable} = AgentConnector.status(dead)
    assert {:error, :unavailable} = AgentConnector.cancel(dead, Identifier.uuid())

    assert {:error, :unavailable} =
             AgentConnector.investigate(dead, nil, "token", "scope", %{}, 0)

    connector = connector(adapter: nil)
    assert {:error, :not_found} = AgentConnector.cancel(connector, Identifier.uuid())
    send(connector, {:agent_timeout, Identifier.uuid(), make_ref()})
    send(connector, {:DOWN, make_ref(), :process, self(), :normal})
    send(connector, :unknown_control)
    assert {:status, ^connector, _, _} = :sys.get_status(connector)
    assert Process.alive?(connector)
  end

  test "Action output remains a policy disposition and never an execution" do
    context = service()
    {thing, td} = materialized(context)
    request_id = Identifier.uuid()

    action = %{
      "input" => %{"type" => "integer", "minimum" => 0, "maximum" => 10, "multipleOf" => 2},
      "forms" => [%{"href" => "https://device.invalid/diagnose", "op" => "invokeaction"}]
    }

    td = Map.put(td, "actions", %{"diagnose" => action})

    assert {:ok, projection} =
             AgentProjection.project(
               td,
               "3",
               disclosure(thing, "3", [], ["diagnose"])
             )

    [tool] = projection["tools"]
    provider_result = provider_result(request_id, [%{"tool_id" => tool["id"], "arguments" => 4}])

    assert {:ok, %{"proposals" => [denied]}} =
             AgentConnector.finalize(
               projection,
               request_id,
               ["proposal"],
               provider_result,
               nil,
               4096
             )

    assert denied["disposition"] == "denied"

    assert {:ok, %{"proposals" => [pending]}} =
             AgentConnector.finalize(
               projection,
               request_id,
               ["proposal"],
               provider_result,
               ["diagnose"],
               4096
             )

    assert pending["disposition"] == "pending_review"
    refute Map.has_key?(pending, "executed")

    for invalid <- [
          provider_result(request_id, [%{"tool_id" => tool["id"], "arguments" => 3}]),
          provider_result(request_id, [%{"tool_id" => "unknown", "arguments" => 4}]),
          Map.put(provider_result(request_id, []), "request_id", Identifier.uuid()),
          Map.merge(provider_result(request_id, [denied]), %{"finish_reason" => "refused"}),
          Map.put(provider_result(request_id, []), "extra", true)
        ] do
      assert {:error, :unavailable} =
               AgentConnector.finalize(
                 projection,
                 request_id,
                 [],
                 invalid,
                 ["diagnose"],
                 4096
               )
    end

    assert {:error, :response_too_large} =
             AgentConnector.finalize(
               projection,
               request_id,
               [String.duplicate("x", 512)],
               provider_result(request_id, []),
               nil,
               256
             )
  end

  test "connector configuration is closed, finite and redacts authorization" do
    secret = "Bearer private-provider-token"
    assert {:ok, config} = AgentConnectorConfig.admit(config())
    assert config.authorization == secret
    refute inspect(config) =~ secret

    for invalid <- [
          %{},
          Map.put(config(), "extra", true),
          Map.put(config(), "provider", "Private Provider"),
          Map.put(config(), "provider", nil),
          Map.put(config(), "endpoint", "http://provider.invalid/v1"),
          Map.put(config(), "endpoint", "https://user@provider.invalid/v1"),
          Map.put(config(), "endpoint", nil),
          Map.put(config(), "authorization", "bad\nsecret"),
          Map.put(config(), "authorization", nil),
          Map.put(config(), "timeout_ms", 0),
          Map.put(config(), "max_events", 0),
          Map.put(config(), "max_response_bytes", 255),
          Map.put(config(), "max_concurrency", 9)
        ] do
      assert {:error, :invalid_options} =
               AgentConnectorConfig.admit(invalid)
    end

    assert {:error, :invalid_options} = AgentConnector.start_link([])
    assert {:error, :invalid_options} = AgentConnector.start_link(config: %{})
    assert {:error, :invalid_options} = AgentConnector.start_link(config: config(), extra: true)

    assert {:error, :invalid_options} =
             AgentConnector.start_link(config: config(), adapter: :invalid)

    assert {:error, :invalid_options} =
             AgentConnector.start_link(config: config(), proposal_policy: :invalid)

    assert {:error, :invalid_options} =
             AgentConnector.start_link(
               config: config(),
               proposal_policy: %{
                 "schema" => "wtr.agent-proposal-policy.v1",
                 "pending_review" => ["diagnose", "diagnose"]
               }
             )

    available =
      connector(
        adapter: {Peer, %{owner: self(), behavior: :success}},
        proposal_policy: %{
          "schema" => "wtr.agent-proposal-policy.v1",
          "pending_review" => ["diagnose"]
        }
      )

    assert {:ok, %{"availability" => "available"}} = AgentConnector.status(available)
  end

  defp connector(options) do
    {document, options} = Keyword.pop(options, :config, config())

    start_supervised!(
      Supervisor.child_spec(
        {AgentConnector, Keyword.put(options, :config, document)},
        id: make_ref(),
        restart: :temporary
      )
    )
  end

  defp investigate(connector, context, request),
    do:
      AgentConnector.investigate(
        connector,
        context.service,
        context.reader,
        context.scope,
        request,
        context.now
      )

  defp request(thing, generation),
    do: %{
      "schema" => "wtr.agent-investigation-request.v1",
      "request_id" => Identifier.uuid(),
      "prompt" => "Assess the disclosed readings",
      "disclosure" => disclosure(thing, generation, ["temperature"], [])
    }

  defp disclosure(thing, generation, properties, actions),
    do: %{
      "schema" => "wtr.agent-projection-request.v1",
      "thing_id" => thing,
      "expected_generation" => generation,
      "read_properties" => properties,
      "propose_actions" => actions
    }

  defp provider_result(request_id, proposals),
    do: %{
      "schema" => "wtr.agent-provider-result.v1",
      "request_id" => request_id,
      "finish_reason" => "completed",
      "proposals" => proposals
    }

  defp proposal_projection(schema),
    do: %{
      "thing" => %{
        "id" => "urn:uuid:00000000-0000-4000-8000-000000000001",
        "generation" => "3"
      },
      "tools" => [
        %{
          "id" => "wtrtool1_test",
          "mode" => "proposal",
          "name" => "diagnose",
          "input_schema" => schema
        }
      ]
    }

  defp config(changes \\ %{}),
    do:
      Map.merge(
        %{
          "schema" => "wtr.agent-connector.v1",
          "enabled" => true,
          "provider" => "synthetic",
          "endpoint" => "https://provider.invalid/v1",
          "authorization" => "Bearer private-provider-token",
          "timeout_ms" => 1_000,
          "max_events" => 8,
          "max_response_bytes" => 4096,
          "max_concurrency" => 2
        },
        changes
      )

  defp eventually(check, attempts \\ 100)
  defp eventually(check, 0), do: assert(check.())

  defp eventually(check, attempts) do
    unless check.() do
      Process.sleep(5)
      eventually(check, attempts - 1)
    end
  end
end
