defmodule Wotex.Tracker.Service.ActiveProbe do
  @moduledoc """
  Explicitly started owner for authorized, bounded, read-only active probes.

  Every request rechecks `interact` authority before a configured adapter sees
  its closed transport target. Adapter work runs in a linked and monitored
  process with finite concurrency, response and deadline budgets. Caller loss,
  explicit cancellation and deadline expiry terminate that work. A successful
  result is private probe evidence only; it does not enroll a peer, resolve a
  profile, create a Thing or execute a physical Action.
  """

  use GenServer

  alias Wotex.Tracker.Service

  alias Wotex.Tracker.Service.{
    ActiveProbeConfig,
    Codec,
    Identifier
  }

  @request_schema "wtr.active-probe-request.v1"
  @adapter_schema "wtr.active-probe-adapter-request.v1"
  @result_schema "wtr.active-probe-result.v1"
  @identity ~r/\Awtr-json-v1:sha256:[0-9a-f]{64}\z/

  @doc "Starts one explicitly enabled probe owner, or returns `:ignore` when disabled."
  @spec start_link(keyword()) :: GenServer.on_start() | :ignore
  def start_link(options) do
    with {:ok, admitted} <- options(options) do
      case admitted do
        :disabled -> :ignore
        state -> GenServer.start_link(__MODULE__, state)
      end
    end
  end

  @doc "Runs one authorized read-only probe under the configured finite budgets."
  @spec probe(pid(), Service.t(), String.t(), String.t(), map(), integer()) ::
          {:ok, map()} | {:error, atom()}
  def probe(owner, service, token, scope, request, now) do
    GenServer.call(owner, {:probe, service, token, scope, request, now}, :infinity)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc "Cancels one current probe independently of its requesting process."
  @spec cancel(pid(), String.t()) :: :ok | {:error, :not_found | :unavailable}
  def cancel(owner, request_id) do
    GenServer.call(owner, {:cancel, request_id})
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc "Returns redacted host-only availability and finite-capacity state."
  @spec status(pid()) :: {:ok, map()} | {:error, :unavailable}
  def status(owner) do
    GenServer.call(owner, :status)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @impl true
  def init(state) do
    Process.flag(:trap_exit, true)
    {:ok, Map.put(state, :requests, %{})}
  end

  @impl true
  def handle_call(:status, _from, state) do
    availability = if state.available, do: "available", else: "unavailable"
    status = ActiveProbeConfig.status(state.config, availability, map_size(state.requests))
    {:reply, {:ok, status}, state}
  end

  def handle_call({:cancel, request_id}, _from, state) do
    case Map.has_key?(state.requests, request_id) do
      true -> {:reply, :ok, finish(state, request_id, {:error, :cancelled}, true)}
      false -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(
        {:probe, _service, _token, _scope, _request, _now},
        _from,
        %{available: false} = state
      ),
      do: {:reply, {:error, :unavailable}, state}

  def handle_call({:probe, service, token, scope, request, now}, from, state) do
    with :ok <- admit_request(request),
         {:ok, plan} <-
           ActiveProbeConfig.plan(state.config, request["profile"], request["probe"]),
         false <- Map.has_key?(state.requests, request["request_id"]),
         true <- map_size(state.requests) < state.config.max_concurrency,
         {:ok, _access} <-
           Service.authorize(service, token, scope, "interact", "active_probe", now) do
      {:noreply, start_request(state, from, request, plan)}
    else
      true -> {:reply, {:error, :conflict}, state}
      false -> {:reply, {:error, :overloaded}, state}
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_info({:active_probe_result, request_id, worker, result}, state) do
    case Map.fetch(state.requests, request_id) do
      {:ok, %{worker: ^worker} = request} ->
        {:noreply, finish(state, request_id, result(result, request), false)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:active_probe_timeout, request_id, token}, state) do
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

  defp start_request(state, from, request, plan) do
    parent = self()
    request_id = request["request_id"]
    adapter = state.adapter
    context = state.adapter_context
    adapter_request = adapter_request(plan)
    timeout_ms = plan["timeout_ms"]

    {worker, worker_monitor} =
      :erlang.spawn_opt(
        fn ->
          result = call_adapter(adapter, context, adapter_request, timeout_ms)
          send(parent, {:active_probe_result, request_id, self(), result})
        end,
        [:link, :monitor]
      )

    caller_monitor = Process.monitor(elem(from, 0))
    timeout_token = make_ref()

    timeout =
      Process.send_after(self(), {:active_probe_timeout, request_id, timeout_token}, timeout_ms)

    inflight = %{
      from: from,
      caller_monitor: caller_monitor,
      worker: worker,
      worker_monitor: worker_monitor,
      timeout: timeout,
      timeout_token: timeout_token,
      request: request,
      plan: plan,
      adapter_request: adapter_request
    }

    put_in(state.requests[request_id], inflight)
  end

  defp call_adapter(adapter, context, request, timeout_ms) do
    case adapter.read(context, request, timeout_ms) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:error, reason} when reason in [:rejected, :unavailable] -> {:error, reason}
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp result({:error, :rejected}, _request), do: {:error, :probe_rejected}
  defp result({:error, :unavailable}, _request), do: {:error, :unavailable}

  defp result({:ok, value}, request) do
    input = request.request
    plan = request.plan

    if byte_size(value) <= plan["max_value_bytes"] do
      {:ok,
       %{
         "schema" => @result_schema,
         "request_id" => input["request_id"],
         "observation_identity" => input["observation_identity"],
         "profile" => input["profile"],
         "probe" => input["probe"],
         "transport" => plan["transport"],
         "operation" => plan["operation"],
         "target" => public_target(plan["target"]),
         "target_identity" => Codec.digest(request.adapter_request["target"]),
         "value" => %{
           "encoding" => "base64",
           "bytes" => byte_size(value),
           "data" => Base.encode64(value)
         }
       }}
    else
      {:error, :response_too_large}
    end
  end

  defp result(_, _), do: {:error, :unavailable}

  defp adapter_request(plan) do
    %{
      "schema" => @adapter_schema,
      "transport" => plan["transport"],
      "operation" => plan["operation"],
      "target" => plan["target"]
    }
  end

  defp public_target(target) do
    Map.take(target, ~w(service_uuid characteristic_uuid handle generation))
  end

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
           "observation_identity" => observation_identity,
           "profile" => profile,
           "probe" => probe
         } = request
       )
       when map_size(request) == 5 do
    with true <- Identifier.operation?(request_id),
         true <-
           is_binary(observation_identity) and Regex.match?(@identity, observation_identity),
         true <- revision?(profile, "version"),
         true <- revision?(probe, "revision") do
      :ok
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp admit_request(_), do: {:error, :invalid_request}

  defp revision?(%{"id" => id, "version" => revision} = value, "version")
       when map_size(value) == 2,
       do: label?(id) and label?(revision)

  defp revision?(%{"id" => id, "revision" => revision} = value, "revision")
       when map_size(value) == 2,
       do: label?(id) and label?(revision)

  defp revision?(_, _), do: false

  defp label?(value) when is_binary(value) and byte_size(value) in 1..128,
    do: String.valid?(value) and not String.contains?(value, ["\0", "\r", "\n"])

  defp label?(_), do: false

  defp options(options) do
    with true <- Keyword.keyword?(options),
         true <- length(options) == length(Enum.uniq(Keyword.keys(options))),
         true <- Enum.all?(Keyword.keys(options), &(&1 in [:adapter, :catalogue, :config])),
         true <- Keyword.has_key?(options, :config),
         {:ok, config} <- enabled_config(ActiveProbeConfig.admit(options[:config])),
         {:ok, config} <- bound_config(config, options[:catalogue]),
         {:ok, adapter, context} <- adapter(Keyword.get(options, :adapter)) do
      {:ok,
       %{
         config: config,
         adapter: adapter,
         adapter_context: context,
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

  defp bound_config(config, catalogue), do: ActiveProbeConfig.bind(config, catalogue)

  defp adapter(nil), do: {:ok, nil, nil}
  defp adapter({module, context}) when is_atom(module), do: {:ok, module, context}
  defp adapter(_), do: {:error, :invalid_options}

  defp compatible?(nil), do: false

  defp compatible?(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :read, 3)
end
