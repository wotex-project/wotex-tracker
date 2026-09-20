defmodule Wotex.Tracker.Service.ActionDispatcher do
  @moduledoc """
  Explicit supervised dispatcher for durable physical Action intents.

  Each intent is reauthorized and bound to the exact current Thing revision
  before claim. Claim durably changes it to `unknown` before WoTEx Runtime sees
  it, so process loss, timeout or an ambiguous transport failure can never cause
  an automatic second physical attempt. Runtime success is protocol acceptance,
  not evidence of a device effect.
  """

  use GenServer

  alias Wotex.Runtime.{ConsumedThing, Context, Error, Result}
  alias Wotex.ThingDescription
  alias Wotex.Tracker.Service.{Codec, Credentials, Store}

  @maximum_batch 32
  @maximum_interval 60_000
  @maximum_timeout 30_000
  @supervisor_lookup_timeout 250

  @doc "Starts one caller-owned Action dispatcher with explicit Runtime ports."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @doc "Requests an immediate bounded dispatch cycle."
  @spec dispatch(pid()) :: :ok | {:error, :busy}
  def dispatch(dispatcher), do: GenServer.call(dispatcher, :dispatch)

  @doc "Returns host-only dispatcher state without Action input or credentials."
  @spec snapshot(pid()) :: {:ok, map()} | {:error, :storage_unavailable}
  def snapshot(dispatcher) do
    GenServer.call(dispatcher, :snapshot)
  catch
    :exit, _ -> {:error, :storage_unavailable}
  end

  @impl true
  def init(options) do
    with {:ok, state} <- options(options), do: {:ok, schedule(%{state | timer: nil}, 0)}
  end

  @impl true
  def handle_call(:dispatch, _from, %{worker: nil} = state) do
    {:reply, :ok, start_cycle(cancel_timer(state))}
  end

  def handle_call(:dispatch, _from, state), do: {:reply, {:error, :busy}, state}

  def handle_call(:snapshot, _from, state) do
    {:reply,
     {:ok,
      %{
        "schema" => "wtr.action-dispatcher.v1",
        "running" => not is_nil(state.worker),
        "last_result" => state.last_result
      }}, state}
  end

  @impl true
  def handle_info(:dispatch, %{worker: nil} = state),
    do: {:noreply, start_cycle(%{state | timer: nil})}

  def handle_info(:dispatch, state), do: {:noreply, state}

  def handle_info({:cycle_result, token, result}, %{worker: %{token: token}} = state) do
    Process.demonitor(state.worker.monitor, [:flush])
    cancel_timeout(state.worker.timeout)
    {:noreply, schedule(%{state | worker: nil, last_result: result}, state.interval_ms)}
  end

  def handle_info({:cycle_timeout, token}, %{worker: %{token: token, pid: pid}} = state) do
    Process.exit(pid, :kill)
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, monitor, :process, _pid, _reason},
        %{worker: %{monitor: monitor}} = state
      ) do
    cancel_timeout(state.worker.timeout)

    result = %{
      "claimed" => 0,
      "accepted" => 0,
      "denied" => 0,
      "failed" => 1,
      "unknown" => 0
    }

    {:noreply, schedule(%{state | worker: nil, last_result: result}, state.interval_ms)}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    cancel_timer(state)
    if state.worker, do: Process.exit(state.worker.pid, :kill)
    :ok
  end

  @impl true
  def format_status(status),
    do: Map.merge(status, %{state: :redacted, message: :redacted, reason: :redacted})

  defp start_cycle(state) do
    parent = self()
    token = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        result = cycle(state)
        send(parent, {:cycle_result, token, result})
      end)

    timeout = Process.send_after(self(), {:cycle_timeout, token}, state.timeout_ms)
    %{state | worker: %{pid: pid, monitor: monitor, token: token, timeout: timeout}}
  end

  defp cycle(state) do
    initial = %{claimed: 0, accepted: 0, denied: 0, failed: 0, unknown: 0}

    result =
      case store(state) do
        {:ok, store} -> reduce_scopes(store, state, initial)
        _ -> %{initial | failed: 1}
      end

    Map.new(result, fn {key, value} -> {Atom.to_string(key), value} end)
  rescue
    _ -> failed_result()
  catch
    :exit, _ -> failed_result()
    _, _ -> failed_result()
  end

  defp reduce_scopes(store, state, initial) do
    Enum.reduce_while(state.scopes, initial, fn scope, counts ->
      if counts.claimed == state.max_batch do
        {:halt, counts}
      else
        reduce_scope(store, scope, state, counts)
      end
    end)
  end

  defp reduce_scope(store, scope, state, counts) do
    remaining = state.max_batch - counts.claimed

    case Store.claim_actions(store, scope, state.clock.(), remaining) do
      {:ok, %{"items" => items, "denied" => denied}} ->
        counts = %{
          counts
          | claimed: counts.claimed + length(items),
            denied: counts.denied + denied
        }

        {:cont, Enum.reduce(items, counts, &invoke(store, &1, state, &2))}

      _ ->
        {:halt, %{counts | failed: counts.failed + 1}}
    end
  end

  defp invoke(store, item, state, counts) do
    completion = runtime_completion(item, state)

    case Store.settle_action(
           store,
           item["scope"],
           item["principal"],
           item["operation_id"],
           item["intent_identity"],
           completion
         ) do
      {:ok, _} -> Map.update!(counts, completion.status, &(&1 + 1))
      _ -> %{counts | failed: counts.failed + 1}
    end
  end

  defp runtime_completion(item, state) do
    outcome =
      with {:ok, td} <- ThingDescription.from_map(item["thing_description"]),
           {:ok, consumed} <- ConsumedThing.new(td, Map.to_list(state.runtime)),
           {:ok, context} <-
             Context.new(
               request_id: item["operation_id"],
               deadline: state.monotonic_clock.() + state.timeout_ms
             ) do
        ConsumedThing.invoke_action(consumed, item["action"], item["input"], context)
      end

    completion(outcome, state.clock.())
  end

  defp completion({:ok, %Result{status: :ok}}, now),
    do: %{status: :accepted, classification: "protocol_ok", at: now}

  defp completion({:ok, %Result{status: :accepted}}, now),
    do: %{status: :accepted, classification: "protocol_accepted", at: now}

  defp completion({:error, %Error{phase: phase}}, now)
       when phase in [:construction, :selection, :credentials],
       do: %{status: :failed, classification: "runtime_#{phase}", at: now}

  defp completion({:error, errors}, now) when is_list(errors),
    do: %{status: :failed, classification: "runtime_construction", at: now}

  defp completion({:error, %Wotex.Error{}}, now),
    do: %{status: :failed, classification: "runtime_construction", at: now}

  defp completion(_, now),
    do: %{status: :unknown, classification: "transport_unknown", at: now}

  defp options(options) do
    defaults = [
      scopes: nil,
      interval_ms: 1_000,
      max_batch: 8,
      timeout_ms: 5_000,
      clock: fn -> System.system_time(:millisecond) end,
      monotonic_clock: fn -> System.monotonic_time(:millisecond) end
    ]

    with true <- admitted_options?(options, defaults),
         merged = defaults |> Keyword.merge(options) |> Map.new(),
         {:ok, credentials} <- Credentials.validate(merged.credentials),
         scopes = merged.scopes || Credentials.scopes(credentials),
         true <- valid_options?(merged, scopes) do
      {:ok,
       Map.merge(merged, %{
         credentials: credentials,
         scopes: scopes,
         timer: nil,
         worker: nil,
         last_result: nil
       })}
    else
      _ -> {:error, :invalid_options}
    end
  end

  defp admitted_options?(options, defaults) do
    Keyword.keyword?(options) and length(options) == length(Enum.uniq(Keyword.keys(options))) and
      Enum.all?(
        Keyword.keys(options),
        &(&1 in [:store, :credentials, :runtime | Keyword.keys(defaults)])
      ) and Enum.all?([:store, :credentials, :runtime], &Keyword.has_key?(options, &1))
  end

  defp valid_options?(value, scopes) do
    store_source?(value.store) and runtime?(value.runtime) and scopes?(scopes) and
      value.interval_ms in 1..@maximum_interval and value.max_batch in 1..@maximum_batch and
      value.timeout_ms in 1..@maximum_timeout and is_function(value.clock, 0) and
      is_function(value.monotonic_clock, 0)
  end

  defp runtime?(%{profiles: profiles, transports: transports, credentials: {module, _}} = runtime)
       when map_size(runtime) == 3,
       do:
         is_list(profiles) and profiles != [] and is_map(transports) and is_atom(module) and
           Code.ensure_loaded?(module) and
           function_exported?(module, :resolve, 4)

  defp runtime?(_), do: false

  defp store_source?(%Store{}), do: true
  defp store_source?({:supervisor, supervisor}), do: is_pid(supervisor)
  defp store_source?(_), do: false

  defp scopes?(scopes),
    do:
      is_list(scopes) and scopes != [] and length(scopes) <= 64 and
        scopes == Enum.sort(Enum.uniq(scopes)) and Enum.all?(scopes, &Codec.id?/1)

  defp store(%{store: %Store{} = store}), do: {:ok, store}

  defp store(%{store: {:supervisor, supervisor}}) do
    task =
      Task.async(fn ->
        try do
          {:ok, Supervisor.which_children(supervisor)}
        catch
          :exit, _ -> {:error, :storage_unavailable}
        end
      end)

    case Task.yield(task, @supervisor_lookup_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, children}} ->
        case List.keyfind(children, :store, 0) do
          {:store, pid, _, _} when is_pid(pid) -> {:ok, Store.handle(pid)}
          _ -> {:error, :storage_unavailable}
        end

      _ ->
        {:error, :storage_unavailable}
    end
  end

  defp failed_result,
    do: %{"claimed" => 0, "accepted" => 0, "denied" => 0, "failed" => 1, "unknown" => 0}

  defp schedule(state, delay), do: %{state | timer: Process.send_after(self(), :dispatch, delay)}
  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(state) do
    Process.cancel_timer(state.timer)
    %{state | timer: nil}
  end

  defp cancel_timeout(reference) when is_reference(reference), do: Process.cancel_timer(reference)
  defp cancel_timeout(_), do: :ok
end
