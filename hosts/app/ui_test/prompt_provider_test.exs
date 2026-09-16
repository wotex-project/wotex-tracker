defmodule Wotex.Tracker.Host.Browser.PromptProviderTest do
  @moduledoc false
  use ExUnit.Case, async: false
  alias Wotex.Tracker.Host.Browser.{OpenAI, PromptProvider}

  defmodule Peer do
    @moduledoc false
    def request(config, request) do
      send(config.test_pid, {:started, self(), request})

      receive do
        {:answer, answer} -> answer
        :crash -> raise "synthetic provider crash"
      end
    end
  end

  defmodule FakeHTTP do
    @moduledoc false
    def connect(:https, host, port, options) do
      Process.put(:http_connect, {host, port, options})

      if Process.get(:http_mode) == :connect_error,
        do: {:error, :closed},
        else: {:ok, :connection}
    end

    def request(conn, method, path, headers, body) do
      Process.put(:http_request, {method, path, headers, body})
      ref = make_ref()
      Process.put(:http_ref, ref)

      if Process.get(:http_mode) == :request_error,
        do: {:error, conn, :closed},
        else: {:ok, conn, ref}
    end

    def recv(conn, 0, _timeout) do
      ref = Process.get(:http_ref)

      case Process.get(:http_mode) do
        :recv_error ->
          {:error, conn, :closed, []}

        :stream_error ->
          {:ok, conn, [{:status, ref, 200}, {:error, ref, :closed}]}

        :noise ->
          {:ok, conn,
           [
             {:status, ref, 200},
             {:headers, ref, []},
             {:data, ref, Process.get(:http_body)},
             {:done, ref}
           ]}

        :status_error ->
          {:ok, conn, [{:status, ref, 401}, {:done, ref}]}

        :oversize ->
          {:ok, conn, [{:status, ref, 200}, {:data, ref, String.duplicate("x", 40_000)}]}

        :split ->
          case Process.get(:http_reads, 0) do
            0 ->
              Process.put(:http_reads, 1)
              {:ok, conn, [{:status, ref, 200}, {:data, ref, Process.get(:http_body)}]}

            _ ->
              {:ok, conn, [{:done, ref}]}
          end

        _ ->
          {:ok, conn, [{:status, ref, 200}, {:data, ref, Process.get(:http_body)}, {:done, ref}]}
      end
    end

    def close(conn) do
      Process.put(:http_closed, true)
      {:ok, conn}
    end
  end

  setup do
    supervisor = start_supervised!({Task.Supervisor, []})

    config = %{
      test_pid: self(),
      max_concurrent: 1,
      max_requests_per_minute: 2,
      timeout_ms: 1_000
    }

    provider =
      start_supervised!(
        {PromptProvider, config: config, task_supervisor: supervisor, requester: Peer}
      )

    %{provider: provider, config: config}
  end

  test "concurrency and rate budgets admit only bounded work", c do
    first = Task.async(fn -> PromptProvider.propose(c.provider, %{"question" => "first"}) end)
    assert_receive {:started, first_pid, %{"question" => "first"}}

    assert {:error, %{"code" => "overloaded"}} =
             PromptProvider.propose(c.provider, %{"question" => "second"})

    send(first_pid, {:answer, {:ok, %{"kind" => "clarify", "question" => "Which day?"}}})
    assert {:ok, %{"kind" => "clarify"}} = Task.await(first)

    second = Task.async(fn -> PromptProvider.propose(c.provider, %{"question" => "second"}) end)
    assert_receive {:started, second_pid, %{"question" => "second"}}
    send(second_pid, {:answer, {:error, %{"code" => "prompt_invalid"}}})
    assert {:error, %{"code" => "prompt_invalid"}} = Task.await(second)

    assert {:error, %{"code" => "overloaded"}} =
             PromptProvider.propose(c.provider, %{"question" => "third"})
  end

  test "deadline and caller loss terminate unfinished provider work", c do
    deadline_config = %{c.config | timeout_ms: 100}

    deadline_provider =
      start_supervised!(
        {PromptProvider,
         config: deadline_config,
         task_supervisor: start_supervised!({Task.Supervisor, []}, id: :deadline_tasks),
         requester: Peer},
        id: :deadline_provider
      )

    waiting = Task.async(fn -> PromptProvider.propose(deadline_provider, %{}) end)
    assert_receive {:started, request_pid, %{}}
    monitor = Process.monitor(request_pid)
    assert {:error, %{"code" => "prompt_unavailable"}} = Task.await(waiting)
    assert_receive {:DOWN, ^monitor, :process, ^request_pid, _}

    caller = spawn(fn -> PromptProvider.propose(c.provider, %{"question" => "abandoned"}) end)
    assert_receive {:started, abandoned_pid, %{"question" => "abandoned"}}
    abandoned = Process.monitor(abandoned_pid)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^abandoned, :process, ^abandoned_pid, _}

    next = Task.async(fn -> PromptProvider.propose(c.provider, %{"question" => "next"}) end)
    assert_receive {:started, next_pid, %{"question" => "next"}}
    send(next_pid, {:answer, {:error, %{"code" => "prompt_unavailable"}}})
    assert {:error, %{"code" => "prompt_unavailable"}} = Task.await(next)
  end

  test "crashed tasks and absent provider leave later questions usable", c do
    assert {:error, %{"code" => "prompt_unavailable"}} =
             PromptProvider.propose(:nonexistent_prompt_provider, %{})

    waiting = Task.async(fn -> PromptProvider.propose(c.provider, %{"question" => "first"}) end)
    assert_receive {:started, request_pid, _}
    send(request_pid, :crash)
    assert {:error, %{"code" => "prompt_unavailable"}} = Task.await(waiting)

    send(c.provider, :unexpected_message)
    send(c.provider, {:DOWN, make_ref(), :process, self(), :normal})

    next = Task.async(fn -> PromptProvider.propose(c.provider, %{"question" => "next"}) end)
    assert_receive {:started, next_pid, _}
    send(next_pid, {:answer, :malformed})
    assert {:error, %{"code" => "prompt_unavailable"}} = Task.await(next)

    assert %{state: :redacted, message: :redacted, log: []} =
             PromptProvider.format_status(%{
               state: %{api_key: "secret"},
               message: "secret",
               log: ["secret"]
             })
  end

  test "OpenAI request body excludes readings and rejects excessive estimated cost" do
    config = openai_config()

    context = %{
      "question" => "Temperature today",
      "utc_now" => "2023-11-14T12:00:00Z",
      "measurements" => [%{"kind" => "temperature", "unit" => "Cel", "value" => 24.3}],
      "aggregations" => ~w(count mean),
      "qualities" => ~w(valid suspect),
      "buckets" => ~w(hour day),
      "views" => ~w(line points)
    }

    assert {:ok, body} = OpenAI.body(config, context)
    document = Jason.decode!(body)
    assert document["store"] == false
    assert document["tools"] == []
    assert document["text"]["format"]["strict"] == true
    refute body =~ "24.3"

    assert Jason.decode!(document["input"])["measurements"] ==
             [%{"kind" => "temperature", "unit" => "Cel"}]

    assert {:error, :budget} = OpenAI.body(%{config | max_cost_micro_usd: 1}, context)
    assert {:error, :invalid_context} = OpenAI.body(config, Map.put(context, "history", []))
    assert {:error, :invalid_context} = OpenAI.body(config, nil)
  end

  test "OpenAI response accepts one completed text proposal and rejects malformed output" do
    config = openai_config()

    proposal = %{
      "kind" => "query",
      "measurement" => "temperature",
      "aggregation" => "mean",
      "quality" => "valid",
      "from" => "2023-11-14T00:00:00Z",
      "to" => "2023-11-15T00:00:00Z",
      "bucket" => "hour",
      "view" => "line",
      "explanation" => "Temperature mean",
      "question" => ""
    }

    response = fn proposed ->
      Jason.encode!(%{
        "status" => "completed",
        "output" => [
          %{
            "type" => "message",
            "content" => [%{"type" => "output_text", "text" => Jason.encode!(proposed)}]
          }
        ],
        "usage" => %{"input_tokens" => 250, "output_tokens" => 100}
      })
    end

    assert {:ok, result} = OpenAI.decode_response(config, response.(proposal))
    assert result == Map.delete(proposal, "question")

    assert {:error, :invalid_response} =
             OpenAI.decode_response(
               config,
               response.(Map.put(proposal, "url", "https://bad.example"))
             )

    assert {:error, :invalid_response} =
             OpenAI.decode_response(config, response.(Map.put(proposal, "question", "hidden")))

    assert {:error, :invalid_response} =
             OpenAI.decode_response(config, String.duplicate("x", config.max_response_bytes + 1))

    assert {:error, :invalid_response} = OpenAI.decode_response(config, nil)

    assert {:error, :invalid_response} =
             OpenAI.decode_response(config, response.(Map.put(proposal, "kind", "unknown")))
  end

  test "provider transport sends one schema-only request and bounds response bytes and status" do
    config =
      openai_config()
      |> Map.merge(%{
        endpoint: "https://api.openai.com/v1/responses",
        api_key: "sk-test-private-placeholder",
        timeout_ms: 1_000,
        http: FakeHTTP
      })

    context = %{
      "question" => "Temperature today",
      "utc_now" => "2023-11-14T12:00:00Z",
      "measurements" => [%{"kind" => "temperature", "unit" => "Cel"}],
      "aggregations" => ~w(mean last),
      "qualities" => ~w(valid suspect),
      "buckets" => ~w(hour day),
      "views" => ~w(line points)
    }

    proposal = %{
      "kind" => "clarify",
      "question" => "Which UTC day?",
      "measurement" => "",
      "aggregation" => "",
      "quality" => "",
      "from" => "",
      "to" => "",
      "bucket" => "",
      "view" => "",
      "explanation" => ""
    }

    response =
      Jason.encode!(%{
        "status" => "completed",
        "output" => [
          %{
            "type" => "message",
            "content" => [%{"type" => "output_text", "text" => Jason.encode!(proposal)}]
          }
        ],
        "usage" => %{"input_tokens" => 250, "output_tokens" => 100}
      })

    Process.put(:http_body, response)
    Process.put(:http_mode, :split)
    Process.delete(:http_reads)

    assert {:ok, %{"kind" => "clarify", "question" => "Which UTC day?"}} =
             OpenAI.request(config, context)

    assert Process.get(:http_closed)
    assert {"api.openai.com", 443, _} = Process.get(:http_connect)
    assert {"POST", "/v1/responses", headers, body} = Process.get(:http_request)
    assert {"authorization", "Bearer sk-test-private-placeholder"} in headers
    refute body =~ "24.3"

    Process.put(:http_mode, :noise)
    assert {:ok, %{"kind" => "clarify"}} = OpenAI.request(config, context)

    for mode <- [
          :connect_error,
          :request_error,
          :recv_error,
          :stream_error,
          :status_error,
          :oversize
        ] do
      Process.put(:http_mode, mode)
      assert {:error, %{"code" => "prompt_unavailable"}} = OpenAI.request(config, context)
    end
  end

  defp openai_config do
    %{
      model: "gpt-5-mini",
      max_request_bytes: 8_192,
      max_response_bytes: 16_384,
      max_output_tokens: 512,
      max_cost_micro_usd: 10_000,
      input_price_micro_usd_per_million: 250_000,
      output_price_micro_usd_per_million: 2_000_000
    }
  end
end
