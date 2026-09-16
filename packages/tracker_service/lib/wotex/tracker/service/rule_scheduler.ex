defmodule Wotex.Tracker.Service.RuleScheduler do
  @moduledoc """
  Explicit bounded scheduler for persisted heartbeat and battery deadlines.

  Absolute receiver times are converted once to local monotonic deadlines. A
  timer never compares those clock domains, and a persisted state change replaces
  the old in-memory deadline. Evaluation and atomic event intent storage still use
  the pure rule and store contracts; this process dispatches no physical action.
  """
  use GenServer

  alias Wotex.Tracker.{BatteryTransition, HeartbeatTransition}
  alias Wotex.Tracker.Service.{RuleTransition, Store}

  @maximum_rules 1_024
  @maximum_refresh_ms 60_000
  @supervisor_lookup_timeout 250

  @doc "Starts one caller-owned scheduler for a store or supervised HTTP host."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @doc "Reloads durable rule states and reconciles their monotonic deadlines."
  @spec refresh(pid()) :: :ok | {:error, atom()}
  def refresh(scheduler), do: GenServer.call(scheduler, :refresh)

  @doc "Returns bounded host-only deadline metadata without rule evidence payloads."
  @spec snapshot(pid()) :: {:ok, map()} | {:error, :storage_unavailable}
  def snapshot(scheduler) do
    GenServer.call(scheduler, :snapshot)
  catch
    :exit, _ -> {:error, :storage_unavailable}
  end

  @impl true
  def init(options) do
    case options(options) do
      {:ok, state} ->
        Process.send_after(self(), :refresh, 0)
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    {result, state} = reload(state)
    {:reply, result, schedule_refresh(state)}
  end

  def handle_call(:snapshot, _from, state) do
    jobs =
      state.jobs
      |> Map.values()
      |> Enum.sort_by(&{&1.scope, &1.kind, &1.rule_id})
      |> Enum.map(
        &%{
          "scope" => &1.scope,
          "kind" => &1.kind,
          "rule_id" => &1.rule_id,
          "due_at" => &1.due_at
        }
      )

    {:reply,
     {:ok,
      %{
        "schema" => "wtr.rule-schedule.v1",
        "scheduled" => length(jobs),
        "jobs" => jobs
      }}, state}
  end

  @impl true
  def handle_info(:refresh, state) do
    {_result, state} = reload(state)
    {:noreply, schedule_refresh(state)}
  end

  def handle_info({:deadline, key, token}, state) do
    case state.jobs[key] do
      %{token: ^token} = job -> {:noreply, fire(job, state)}
      _ -> {:noreply, state}
    end
  end

  def handle_info(
        {:DOWN, reference, :process, pid, _},
        %{store_monitor: reference, store: %{pid: pid}} = state
      ),
      do: {:stop, :normal, state}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    cancel_timer(state.refresh_timer)
    Enum.each(state.jobs, fn {_, job} -> cancel_timer(job.timer) end)
    :ok
  end

  @impl true
  def format_status(status),
    do: Map.merge(status, %{state: :redacted, message: :redacted, reason: :redacted})

  defp options(options) do
    defaults = [
      max_rules: @maximum_rules,
      refresh_interval: 1_000,
      clock: fn -> System.system_time(:millisecond) end,
      monotonic_clock: fn -> System.monotonic_time(:millisecond) end
    ]

    if admitted_options?(options, defaults) do
      admitted = defaults |> Keyword.merge(options) |> Map.new()

      if valid_options?(admitted) do
        {:ok,
         Map.merge(admitted, %{
           store_source: admitted.store,
           store: nil,
           store_monitor: nil,
           jobs: %{},
           refresh_timer: nil
         })}
      else
        {:error, :invalid_options}
      end
    else
      {:error, :invalid_options}
    end
  end

  defp admitted_options?(options, defaults) do
    Keyword.keyword?(options) and length(options) == length(Enum.uniq(Keyword.keys(options))) and
      Enum.all?(Keyword.keys(options), &(&1 in [:store | Keyword.keys(defaults)]))
  end

  defp valid_options?(admitted) do
    Map.has_key?(admitted, :store) and store_source?(admitted.store) and
      admitted.max_rules in 1..@maximum_rules and
      admitted.refresh_interval in 1..@maximum_refresh_ms and is_function(admitted.clock, 0) and
      is_function(admitted.monotonic_clock, 0)
  end

  defp store_source?(%Store{}), do: true
  defp store_source?({:supervisor, supervisor}), do: is_pid(supervisor)
  defp store_source?(_), do: false

  defp reload(state) do
    case store(state) do
      {:ok, store, state} ->
        with {:ok, rows} <- Store.scheduled_rules(store, state.max_rules),
             {:ok, planned} <- plan(rows) do
          {:ok, reconcile(planned, state)}
        else
          {:error, reason} -> {{:error, reason}, state}
        end

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp store(%{store: %Store{} = store} = state), do: {:ok, store, state}

  defp store(%{store_source: %Store{} = store} = state) do
    reference = Process.monitor(store.pid)
    {:ok, store, %{state | store: store, store_monitor: reference}}
  end

  defp store(%{store_source: {:supervisor, supervisor}} = state) do
    with {:ok, children} <- supervisor_children(supervisor) do
      case List.keyfind(children, :store, 0) do
        {:store, pid, _, _} when is_pid(pid) ->
          store = Store.handle(pid)
          reference = Process.monitor(pid)
          {:ok, store, %{state | store: store, store_monitor: reference}}

        _ ->
          {:error, :storage_unavailable}
      end
    end
  end

  defp supervisor_children(supervisor) do
    task =
      Task.async(fn ->
        try do
          {:ok, Supervisor.which_children(supervisor)}
        catch
          :exit, _ -> {:error, :storage_unavailable}
        end
      end)

    case Task.yield(task, @supervisor_lookup_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:error, :storage_unavailable}
    end
  end

  defp plan(rows) do
    Enum.reduce_while(rows, {:ok, %{}}, fn row, {:ok, jobs} ->
      case planned(row) do
        {:ok, nil} -> {:cont, {:ok, jobs}}
        {:ok, job} -> {:cont, {:ok, Map.put(jobs, job.key, job)}}
        error -> {:halt, error}
      end
    end)
  end

  defp planned(%{
         "scope" => scope,
         "kind" => "heartbeat" = kind,
         "rule_id" => rule_id,
         "state_identity" => identity,
         "state" => document
       }) do
    case HeartbeatTransition.state_from_map(document) do
      {:ok, state} ->
        job(scope, kind, rule_id, identity, document, heartbeat_deadline(state))

      _ ->
        {:error, :storage_unavailable}
    end
  end

  defp planned(%{
         "scope" => scope,
         "kind" => "battery" = kind,
         "rule_id" => rule_id,
         "state_identity" => identity,
         "state" => document
       }) do
    case BatteryTransition.state_from_map(document) do
      {:ok, state} ->
        job(scope, kind, rule_id, identity, document, battery_deadline(state))

      _ ->
        {:error, :storage_unavailable}
    end
  end

  defp planned(_), do: {:error, :storage_unavailable}

  defp job(_, _, _, _, _, nil), do: {:ok, nil}

  defp job(scope, kind, rule_id, identity, document, due_at),
    do:
      {:ok,
       %{
         key: {scope, kind, rule_id},
         scope: scope,
         kind: kind,
         rule_id: rule_id,
         state_identity: identity,
         document: document,
         due_at: due_at
       }}

  defp heartbeat_deadline(%{status: "current", due_at: due_at}), do: due_at
  defp heartbeat_deadline(_), do: nil

  defp battery_deadline(state) do
    age = state.evaluated_at - state.sample.observed_at

    cond do
      age < -state.policy.future_skew_ms ->
        state.sample.observed_at - state.policy.future_skew_ms

      state.status in ~w(low normal) ->
        state.sample.observed_at + state.policy.maximum_age_ms + 1

      true ->
        nil
    end
  end

  defp reconcile(planned, state) do
    jobs =
      Enum.reduce(state.jobs, %{}, fn {key, current}, retained ->
        case planned[key] do
          %{state_identity: identity, due_at: due_at}
          when identity == current.state_identity and due_at == current.due_at ->
            Map.put(retained, key, current)

          _ ->
            cancel_timer(current.timer)
            retained
        end
      end)

    jobs =
      Enum.reduce(planned, jobs, fn {key, job}, scheduled ->
        if Map.has_key?(scheduled, key),
          do: scheduled,
          else: Map.put(scheduled, key, schedule(job, state))
      end)

    %{state | jobs: jobs}
  end

  defp schedule(job, state) do
    remaining = max(0, job.due_at - state.clock.())
    monotonic_deadline = state.monotonic_clock.() + remaining
    token = make_ref()
    timer = Process.send_after(self(), {:deadline, job.key, token}, remaining)
    Map.merge(job, %{token: token, timer: timer, monotonic_deadline: monotonic_deadline})
  end

  defp fire(job, state) do
    remaining = job.monotonic_deadline - state.monotonic_clock.()

    if remaining > 0 do
      timer = Process.send_after(self(), {:deadline, job.key, job.token}, remaining)
      put_in(state.jobs[job.key].timer, timer)
    else
      result = tick(job, state.store)
      state = %{state | jobs: Map.delete(state.jobs, job.key)}
      if result == :ok, do: send(self(), :refresh)
      state
    end
  end

  defp tick(job, store) do
    with {:ok, durable} <- Store.rule_state(store, job.scope, job.kind, job.rule_id),
         true <- durable["state_identity"] == job.state_identity,
         {:ok, previous, result} <- evaluate(job.kind, durable["state"], job.due_at),
         true <- result["state_changed"],
         {:ok, transition} <- RuleTransition.new(job.scope, previous, result),
         {:ok, _} <- Store.commit_rule(store, transition) do
      :ok
    else
      false -> :ok
      {:error, _} = error -> error
    end
  end

  defp evaluate("heartbeat", document, now) do
    with {:ok, state} <- HeartbeatTransition.state_from_map(document),
         {:ok, result} <- HeartbeatTransition.evaluate(state, nil, state.policy, :live, now) do
      {:ok, state, result}
    end
  end

  defp evaluate("battery", document, now) do
    with {:ok, state} <- BatteryTransition.state_from_map(document),
         {:ok, result} <- BatteryTransition.evaluate(state, nil, state.policy, :live, now) do
      {:ok, state, result}
    end
  end

  defp schedule_refresh(state) do
    cancel_timer(state.refresh_timer)
    timer = Process.send_after(self(), :refresh, state.refresh_interval)
    %{state | refresh_timer: timer}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer, async: true, info: false)
end
