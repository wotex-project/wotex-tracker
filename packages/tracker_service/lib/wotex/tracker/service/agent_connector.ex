defmodule Wotex.Tracker.Service.AgentConnector do
  @moduledoc """
  Explicit, bounded provider-neutral agent connector.

  Disabled configuration starts no process. Enabled connectors isolate every
  provider call in a monitored process, enforce finite concurrency, response
  and time budgets, and terminate work when its caller cancels or disappears.
  Provider output can propose an admitted Action but this process never executes
  a WoT operation.
  """

  use GenServer

  alias Wotex.Tracker.Service

  alias Wotex.Tracker.Service.{
    AgentConnectorConfig,
    AgentProjection,
    Codec,
    Identifier
  }

  @request_schema "wtr.agent-investigation-request.v1"
  @provider_request_schema "wtr.agent-provider-request.v1"
  @event_schema "wtr.agent-stream-event.v1"
  @provider_result_schema "wtr.agent-provider-result.v1"
  @result_schema "wtr.agent-investigation.v1"
  @maximum_prompt_bytes 8192
  @maximum_proposals 16

  @doc "Starts one explicitly enabled connector, or returns `:ignore` when disabled."
  @spec start_link(keyword()) :: GenServer.on_start() | :ignore
  def start_link(options) do
    with {:ok, admitted} <- options(options) do
      case admitted do
        :disabled -> :ignore
        state -> GenServer.start_link(__MODULE__, state)
      end
    end
  end

  @doc "Runs one authorized investigation under the connector's finite budgets."
  @spec investigate(pid(), Service.t(), String.t(), String.t(), map(), integer()) ::
          {:ok, map()} | {:error, map() | atom()}
  def investigate(connector, service, token, scope, request, now) do
    GenServer.call(connector, {:investigate, service, token, scope, request, now}, :infinity)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc "Cancels one current request without relying on the requesting process."
  @spec cancel(pid(), String.t()) :: :ok | {:error, :not_found | :unavailable}
  def cancel(connector, request_id) do
    GenServer.call(connector, {:cancel, request_id})
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc "Returns redacted host-only availability and finite-capacity state."
  @spec status(pid()) :: {:ok, map()} | {:error, :unavailable}
  def status(connector) do
    GenServer.call(connector, :status)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc false
  def finalize(projection, request_id, chunks, result, policy, max_response_bytes)
      when is_map(projection) and is_list(chunks) and is_integer(max_response_bytes) do
    with :ok <- admit_provider_result(result, request_id),
         true <- Enum.all?(chunks, &(is_binary(&1) and String.valid?(&1))),
         {:ok, proposals} <- proposals(result["proposals"], projection, request_id, policy),
         response = %{
           "schema" => @result_schema,
           "request_id" => result["request_id"],
           "thing" => projection["thing"],
           "finish_reason" => result["finish_reason"],
           "answer" => IO.iodata_to_binary(chunks),
           "proposals" => proposals
         },
         {:ok, _encoded} <- Codec.encode(response, max_response_bytes) do
      {:ok, response}
    else
      {:error, :invalid_json} -> {:error, :response_too_large}
      {:error, _} = error -> error
      _ -> {:error, :unavailable}
    end
  end

  def finalize(_, _, _, _, _, _), do: {:error, :unavailable}

  @impl true
  def init(state) do
    Process.flag(:trap_exit, true)
    {:ok, Map.put(state, :requests, %{})}
  end

  @impl true
  def handle_call(:status, _from, state) do
    availability = if state.available, do: "available", else: "unavailable"
    status = AgentConnectorConfig.status(state.config, availability, map_size(state.requests))
    {:reply, {:ok, status}, state}
  end

  def handle_call({:cancel, request_id}, _from, state) do
    case Map.has_key?(state.requests, request_id) do
      true -> {:reply, :ok, finish(state, request_id, {:error, :cancelled}, true)}
      false -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(
        {:investigate, _service, _token, _scope, _request, _now},
        _from,
        %{available: false} = state
      ),
      do: {:reply, {:error, :unavailable}, state}

  def handle_call({:investigate, service, token, scope, request, now}, from, state) do
    with :ok <- admit_request(request),
         false <- Map.has_key?(state.requests, request["request_id"]),
         true <- map_size(state.requests) < state.config.max_concurrency,
         {:ok, projection} <-
           Service.agent_tools(service, token, scope, request["disclosure"], now) do
      {:noreply, start_request(state, from, request, projection)}
    else
      true -> {:reply, {:error, :conflict}, state}
      false -> {:reply, {:error, :overloaded}, state}
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_info({:agent_event, request_id, worker, acknowledgement, event}, state) do
    case Map.fetch(state.requests, request_id) do
      {:ok, %{worker: ^worker} = request} ->
        case accept_event(event, request, state.config) do
          {:ok, updated} ->
            send(worker, {acknowledgement, :ok})
            {:noreply, put_in(state.requests[request_id], updated)}

          {:error, reason} ->
            send(worker, {acknowledgement, {:error, reason}})
            {:noreply, finish(state, request_id, {:error, reason}, true)}
        end

      _ ->
        send(worker, {acknowledgement, {:error, :cancelled}})
        {:noreply, state}
    end
  end

  def handle_info({:agent_result, request_id, worker, result}, state) do
    case Map.fetch(state.requests, request_id) do
      {:ok, %{worker: ^worker} = request} ->
        reply = provider_result(result, request, state)
        {:noreply, finish(state, request_id, reply, false)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:agent_timeout, request_id, token}, state) do
    case Map.fetch(state.requests, request_id) do
      {:ok, %{timeout_token: ^token}} ->
        {:noreply, finish(state, request_id, {:error, :deadline_exceeded}, true)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case request_for_monitor(state.requests, monitor) do
      {request_id, :caller} ->
        {:noreply, finish(state, request_id, {:error, :cancelled}, true)}

      {request_id, :worker} ->
        {:noreply, finish(state, request_id, {:error, :unavailable}, false)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    Enum.each(state.requests, fn {_request_id, request} -> Process.exit(request.worker, :kill) end)

    :ok
  end

  @impl true
  def format_status(status),
    do: Map.merge(status, %{state: :redacted, message: :redacted, reason: :redacted})

  defp start_request(state, from, request, projection) do
    parent = self()
    request_id = request["request_id"]
    config = state.config
    adapter = state.adapter
    adapter_context = state.adapter_context

    provider_request = %{
      "schema" => @provider_request_schema,
      "request_id" => request_id,
      "prompt" => request["prompt"],
      "tools" => projection
    }

    {worker, worker_monitor} =
      :erlang.spawn_opt(
        fn ->
          emit = fn event -> emit(parent, request_id, event, config.timeout_ms) end
          result = call_adapter(adapter, adapter_context, config, provider_request, emit)
          send(parent, {:agent_result, request_id, self(), result})
        end,
        [:link, :monitor]
      )

    caller_monitor = Process.monitor(elem(from, 0))
    timeout_token = make_ref()

    timeout =
      Process.send_after(self(), {:agent_timeout, request_id, timeout_token}, config.timeout_ms)

    inflight = %{
      request_id: request_id,
      from: from,
      caller_monitor: caller_monitor,
      worker: worker,
      worker_monitor: worker_monitor,
      timeout: timeout,
      timeout_token: timeout_token,
      projection: projection,
      chunks: [],
      event_count: 0,
      response_bytes: 0,
      next_sequence: 0
    }

    put_in(state.requests[request_id], inflight)
  end

  defp emit(connector, request_id, event, timeout_ms) do
    acknowledgement = make_ref()
    send(connector, {:agent_event, request_id, self(), acknowledgement, event})

    receive do
      {^acknowledgement, result} -> result
    after
      timeout_ms -> {:error, :cancelled}
    end
  end

  defp call_adapter(adapter, context, config, request, emit) do
    case adapter.investigate(context, config, request, emit) do
      {:ok, result} when is_map(result) -> {:ok, result}
      {:error, reason} when reason in [:rejected, :unavailable] -> {:error, reason}
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp accept_event(
         %{
           "schema" => @event_schema,
           "request_id" => request_id,
           "sequence" => sequence,
           "kind" => "text_delta",
           "text" => text
         } = event,
         request,
         config
       )
       when map_size(event) == 5 and is_binary(text) and text != "" do
    bytes = request.response_bytes + byte_size(text)
    count = request.event_count + 1

    cond do
      request_id != request.request_id ->
        {:error, :unavailable}

      sequence != request.next_sequence or not String.valid?(text) ->
        {:error, :unavailable}

      count > config.max_events or bytes > config.max_response_bytes ->
        {:error, :response_too_large}

      true ->
        {:ok,
         %{
           request
           | chunks: [text | request.chunks],
             event_count: count,
             response_bytes: bytes,
             next_sequence: sequence + 1
         }}
    end
  end

  defp accept_event(_, _, _), do: {:error, :unavailable}

  defp provider_result({:error, :rejected}, _request, _state), do: {:error, :forbidden}
  defp provider_result({:error, :unavailable}, _request, _state), do: {:error, :unavailable}

  defp provider_result({:ok, result}, request, state) do
    finalize(
      request.projection,
      request.request_id,
      Enum.reverse(request.chunks),
      result,
      state.proposal_policy,
      state.config.max_response_bytes
    )
  end

  defp admit_provider_result(
         %{
           "schema" => @provider_result_schema,
           "request_id" => request_id,
           "finish_reason" => finish_reason,
           "proposals" => proposals
         } = result,
         expected_request_id
       )
       when map_size(result) == 4 and finish_reason in ~w(completed refused) and
              is_list(proposals) and length(proposals) <= @maximum_proposals do
    cond do
      request_id != expected_request_id -> {:error, :unavailable}
      finish_reason == "refused" and proposals != [] -> {:error, :unavailable}
      true -> :ok
    end
  end

  defp admit_provider_result(_, _), do: {:error, :unavailable}

  defp proposals(values, projection, request_id, policy) do
    Enum.reduce_while(values, {:ok, []}, fn proposal, {:ok, admitted} ->
      case proposal(proposal, projection, request_id, policy) do
        {:ok, value} -> {:cont, {:ok, [value | admitted]}}
        error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, admitted} -> {:ok, Enum.reverse(admitted)}
      error -> error
    end)
  end

  defp proposal(
         %{"tool_id" => tool_id, "arguments" => arguments} = value,
         projection,
         request_id,
         policy
       )
       when map_size(value) == 2 and is_binary(tool_id) do
    with %{"mode" => "proposal"} = tool <-
           Enum.find(projection["tools"], &(&1["id"] == tool_id)),
         true <- arguments?(arguments, tool["input_schema"]) do
      candidate = %{
        "request_id" => request_id,
        "thing" => projection["thing"],
        "tool" => tool,
        "arguments" => arguments
      }

      disposition =
        if policy_decision(policy, candidate) == :allow, do: "pending_review", else: "denied"

      {:ok, Map.put(value, "disposition", disposition)}
    else
      _ -> {:error, :unavailable}
    end
  end

  defp proposal(_, _, _, _), do: {:error, :unavailable}

  defp arguments?(nil, nil), do: true
  defp arguments?(value, %{"type" => "boolean"}), do: is_boolean(value)

  defp arguments?(value, %{"type" => "integer"} = schema),
    do: is_integer(value) and numeric?(value, schema)

  defp arguments?(value, %{"type" => "number"} = schema),
    do: is_number(value) and numeric?(value, schema)

  defp arguments?(value, %{"type" => "string"} = schema) when is_binary(value) do
    String.valid?(value) and length?(value, schema) and not Map.has_key?(schema, "pattern")
  end

  defp arguments?(_, _), do: false

  defp numeric?(value, schema) do
    compare(value, schema["minimum"], &Kernel.>=/2) and
      compare(value, schema["maximum"], &Kernel.<=/2) and
      compare(value, schema["exclusiveMinimum"], &Kernel.>/2) and
      compare(value, schema["exclusiveMaximum"], &Kernel.</2) and
      multiple?(value, schema["multipleOf"])
  end

  defp compare(_value, nil, _comparison), do: true
  defp compare(value, limit, comparison), do: comparison.(value, limit)

  defp multiple?(_value, nil), do: true

  defp multiple?(value, multiple)
       when is_integer(value) and is_integer(multiple) and multiple > 0,
       do: rem(value, multiple) == 0

  defp multiple?(value, multiple) when is_number(multiple) and multiple > 0 do
    quotient = value / multiple
    abs(quotient - Float.round(quotient)) <= 1.0e-12 * max(1.0, abs(quotient))
  end

  defp multiple?(_, _), do: false

  defp length?(value, schema) do
    length = String.length(value)

    (is_nil(schema["minLength"]) or length >= schema["minLength"]) and
      (is_nil(schema["maxLength"]) or length <= schema["maxLength"])
  end

  defp policy_decision(pending_review, candidate) when is_list(pending_review) do
    if candidate["tool"]["name"] in pending_review, do: :allow, else: :deny
  end

  defp policy_decision(_, _), do: :deny

  defp finish(state, request_id, reply, kill_worker) do
    case Map.pop(state.requests, request_id) do
      {nil, _requests} ->
        state

      {request, requests} ->
        if kill_worker and Process.alive?(request.worker), do: Process.exit(request.worker, :kill)
        Process.cancel_timer(request.timeout, async: true, info: false)
        Process.demonitor(request.caller_monitor, [:flush])
        Process.demonitor(request.worker_monitor, [:flush])
        GenServer.reply(request.from, reply)
        %{state | requests: requests}
    end
  end

  defp request_for_monitor(requests, monitor) do
    Enum.find_value(requests, fn {request_id, request} ->
      cond do
        request.caller_monitor == monitor -> {request_id, :caller}
        request.worker_monitor == monitor -> {request_id, :worker}
        true -> nil
      end
    end)
  end

  defp admit_request(
         %{
           "schema" => @request_schema,
           "request_id" => request_id,
           "prompt" => prompt,
           "disclosure" => disclosure
         } = request
       )
       when map_size(request) == 4 and is_binary(prompt) and
              byte_size(prompt) in 1..@maximum_prompt_bytes do
    with true <- Identifier.operation?(request_id),
         true <- String.valid?(prompt) and not String.contains?(prompt, ["\0", "\r"]),
         :ok <- AgentProjection.admit(disclosure) do
      :ok
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp admit_request(_), do: {:error, :invalid_request}

  defp options(options) do
    allowed = [:adapter, :config, :proposal_policy]

    with true <- Keyword.keyword?(options),
         true <- length(options) == length(Enum.uniq(Keyword.keys(options))),
         true <- Enum.all?(Keyword.keys(options), &(&1 in allowed)),
         true <- Keyword.has_key?(options, :config),
         {:ok, config} <- enabled_config(AgentConnectorConfig.admit(options[:config])),
         {:ok, adapter, context} <- adapter(Keyword.get(options, :adapter)),
         {:ok, policy} <- policy(Keyword.get(options, :proposal_policy)) do
      {:ok,
       %{
         config: config,
         adapter: adapter,
         adapter_context: context,
         proposal_policy: policy,
         available: compatible?(adapter)
       }}
    else
      :disabled -> {:ok, :disabled}
      _ -> {:error, :invalid_options}
    end
  end

  defp enabled_config(:disabled), do: :disabled
  defp enabled_config({:ok, config}), do: {:ok, config}
  defp enabled_config(error), do: error

  defp adapter(nil), do: {:ok, nil, nil}
  defp adapter({module, context}) when is_atom(module), do: {:ok, module, context}
  defp adapter(_), do: {:error, :invalid_options}

  defp policy(nil), do: {:ok, []}

  defp policy(
         %{
           "schema" => "wtr.agent-proposal-policy.v1",
           "pending_review" => names
         } = value
       )
       when map_size(value) == 2 and is_list(names) and length(names) <= 32 do
    if names == Enum.sort(Enum.uniq(names)) and Enum.all?(names, &affordance_name?/1),
      do: {:ok, names},
      else: {:error, :invalid_options}
  end

  defp policy(_), do: {:error, :invalid_options}

  defp affordance_name?(value) when is_binary(value) and byte_size(value) in 1..128,
    do: String.valid?(value) and not String.contains?(value, ["\0", "\r", "\n"])

  defp affordance_name?(_), do: false

  defp compatible?(nil), do: false

  defp compatible?(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :investigate, 4)
end
