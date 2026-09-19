defmodule Wotex.Tracker.Service.NotificationDispatcher do
  @moduledoc """
  Explicit supervised dispatcher for durable notification references.

  A bounded worker claims only APNs push items, rechecks the endpoint's retained
  credential against current grants and revocation, and calls one configured
  provider adapter. Retryable or unknown outcomes remain pending. Provider
  acceptance, OS delivery and user reading are intentionally distinct.
  """

  use GenServer

  alias Wotex.Tracker.Service.{
    Codec,
    Credentials,
    NotificationEndpoint,
    NotificationTarget,
    Store
  }

  @maximum_batch 32
  @maximum_interval 60_000
  @maximum_retry 86_400_000
  @maximum_timeout 30_000
  @supervisor_lookup_timeout 250
  @retry_reasons [:unavailable, :timeout, :rate_limited, :server_error]

  @doc "Starts one caller-owned dispatcher; no provider is selected implicitly."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @doc "Requests an immediate bounded dispatch cycle."
  @spec dispatch(pid()) :: :ok | {:error, :busy}
  def dispatch(dispatcher), do: GenServer.call(dispatcher, :dispatch)

  @doc "Returns host-only bounded dispatcher state without endpoint or payload data."
  @spec snapshot(pid()) :: {:ok, map()} | {:error, :storage_unavailable}
  def snapshot(dispatcher) do
    GenServer.call(dispatcher, :snapshot)
  catch
    :exit, _ -> {:error, :storage_unavailable}
  end

  @impl true
  def init(options) do
    with {:ok, state} <- options(options) do
      {:ok, schedule(%{state | timer: nil}, 0)}
    end
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
        "schema" => "wtr.notification-dispatcher.v1",
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
      "discarded" => 0,
      "retrying" => 0,
      "failed" => 1
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
    initial = %{claimed: 0, accepted: 0, discarded: 0, retrying: 0, failed: 0}

    result =
      case store(state) do
        {:ok, store} -> reduce_scopes(store, state, initial)
        _ -> %{initial | failed: 1}
      end

    Map.new(result, fn {key, value} -> {Atom.to_string(key), value} end)
  rescue
    _ -> %{"claimed" => 0, "accepted" => 0, "discarded" => 0, "retrying" => 0, "failed" => 1}
  catch
    :exit, _ ->
      %{"claimed" => 0, "accepted" => 0, "discarded" => 0, "retrying" => 0, "failed" => 1}
  end

  defp reduce_scopes(store, state, initial) do
    Enum.reduce_while(state.scopes, initial, fn scope, counts ->
      reduce_scope(store, scope, state, counts)
    end)
  end

  defp reduce_scope(_store, _scope, state, counts) when counts.claimed == state.max_batch,
    do: {:halt, counts}

  defp reduce_scope(store, scope, state, counts) do
    remaining = state.max_batch - counts.claimed

    case claim_and_deliver(store, scope, remaining, state, counts) do
      {:ok, updated} -> {:cont, updated}
      {:error, updated} -> {:halt, %{updated | failed: updated.failed + 1}}
    end
  end

  defp claim_and_deliver(store, scope, limit, state, counts) do
    now = state.clock.()

    case Store.claim_notifications(store, scope, now, limit, state.retry_after_ms) do
      {:ok, %{"items" => items}} ->
        service = %{store: store, credentials: state.credentials}

        updated =
          Enum.reduce(items, %{counts | claimed: counts.claimed + length(items)}, fn item,
                                                                                     tally ->
            deliver(service, item, state, tally)
          end)

        {:ok, updated}

      _ ->
        {:error, counts}
    end
  end

  defp deliver(service, item, state, counts) do
    now = state.clock.()

    case NotificationEndpoint.resolve(service, item["scope"], item["candidate_id"], now) do
      {:ok, target} ->
        deliver_target(service, target, item, state, counts)

      {:error, reason} when reason in [:endpoint_missing, :endpoint_rotated] ->
        discard(service.store, item, Atom.to_string(reason), now, counts)

      {:error, :authorization_revoked} ->
        discard(service.store, item, "authorization_revoked", now, counts)

      _ ->
        %{counts | retrying: counts.retrying + 1}
    end
  end

  defp deliver_target(service, %NotificationTarget{} = target, item, state, counts) do
    state.adapter
    |> call_adapter(state.adapter_context, target, item["payload"])
    |> handle_delivery_result(service, target, item, state.clock.(), counts)
  end

  defp handle_delivery_result({:accepted, reference}, service, _target, item, now, counts) do
    completion = %{status: :acknowledged, layer: :application, at: now, reference: reference}

    case Store.complete_forward(
           service.store,
           item["scope"],
           item["id"],
           item["queue_identity"],
           completion
         ) do
      {:ok, _} -> %{counts | accepted: counts.accepted + 1}
      _ -> %{counts | failed: counts.failed + 1}
    end
  end

  defp handle_delivery_result({:invalid_token, _}, service, target, item, now, counts) do
    case NotificationEndpoint.invalidate(service, target, item["id"], now) do
      :ok ->
        discard(service.store, item, "invalid_token", now, counts)

      {:error, reason} when reason in [:endpoint_missing, :endpoint_rotated] ->
        discard(service.store, item, Atom.to_string(reason), now, counts)

      _ ->
        %{counts | retrying: counts.retrying + 1}
    end
  end

  defp handle_delivery_result({:rejected, _}, service, _target, item, now, counts),
    do: discard(service.store, item, "provider_rejected", now, counts)

  defp handle_delivery_result({:retry, _}, _service, _target, _item, _now, counts),
    do: %{counts | retrying: counts.retrying + 1}

  defp handle_delivery_result(:invalid, _service, _target, _item, _now, counts),
    do: %{counts | retrying: counts.retrying + 1}

  defp discard(store, item, reason, now, counts) do
    case Store.discard_forward(
           store,
           item["scope"],
           item["id"],
           item["queue_identity"],
           reason,
           now
         ) do
      {:ok, _} -> %{counts | discarded: counts.discarded + 1}
      _ -> %{counts | failed: counts.failed + 1}
    end
  end

  defp call_adapter(adapter, context, target, payload) do
    case adapter.deliver(context, target, payload) do
      {status, reference} when status in [:accepted, :invalid_token, :rejected] ->
        if Codec.id?(reference), do: {status, reference}, else: :invalid

      {:retry, reason} when reason in @retry_reasons ->
        {:retry, reason}

      _ ->
        :invalid
    end
  rescue
    _ -> {:retry, :unavailable}
  catch
    _, _ -> {:retry, :unavailable}
  end

  defp options(options) do
    defaults = [
      scopes: nil,
      interval_ms: 1_000,
      retry_after_ms: 5_000,
      max_batch: 8,
      timeout_ms: 5_000,
      clock: fn -> System.system_time(:millisecond) end
    ]

    with true <- admitted_options?(options, defaults),
         merged = defaults |> Keyword.merge(options) |> Map.new(),
         {:ok, credentials} <- Credentials.validate(merged.credentials),
         scopes = merged.scopes || Credentials.scopes(credentials),
         true <- valid_options?(merged, scopes) do
      {adapter, context} = merged.adapter

      {:ok,
       Map.merge(merged, %{
         credentials: credentials,
         scopes: scopes,
         adapter: adapter,
         adapter_context: context,
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
        &(&1 in [:store, :credentials, :adapter | Keyword.keys(defaults)])
      ) and Enum.all?([:store, :credentials, :adapter], &Keyword.has_key?(options, &1))
  end

  defp valid_options?(value, scopes) do
    store_source?(value.store) and adapter?(value.adapter) and scopes?(scopes) and
      value.interval_ms in 1..@maximum_interval and
      value.retry_after_ms in 1..@maximum_retry and value.max_batch in 1..@maximum_batch and
      value.timeout_ms in 1..@maximum_timeout and is_function(value.clock, 0)
  end

  defp store_source?(%Store{}), do: true
  defp store_source?({:supervisor, supervisor}), do: is_pid(supervisor)
  defp store_source?(_), do: false

  defp adapter?({module, _context}) when is_atom(module),
    do: function_exported?(module, :deliver, 3)

  defp adapter?(_), do: false

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

  defp schedule(state, delay), do: %{state | timer: Process.send_after(self(), :dispatch, delay)}

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(state) do
    Process.cancel_timer(state.timer)
    %{state | timer: nil}
  end

  defp cancel_timeout(reference) when is_reference(reference), do: Process.cancel_timer(reference)
  defp cancel_timeout(_), do: :ok
end
