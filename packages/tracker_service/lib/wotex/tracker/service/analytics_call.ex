defmodule Wotex.Tracker.Service.AnalyticsCall do
  @moduledoc false

  alias Exqlite.Sqlite3
  alias Wotex.Tracker.QuerySpec
  alias Wotex.Tracker.Service.{Access, Analytics, Authority, OperationalTelemetry, SQL}

  @global_limit 8
  @principal_limit 2
  @rate_limit 16
  @rate_window_ms 1_000

  def run(config, %Access{} = access, %QuerySpec{} = spec, now) do
    run(config, access, spec, now, nil)
  end

  def run(_, _, _, _), do: {:error, :invalid_query}

  @doc false
  def run_at(config, %Access{} = access, %QuerySpec{} = spec, now, generation)
      when is_integer(generation) and generation >= 0 do
    run(config, access, spec, now, generation)
  end

  def run_at(_, _, _, _, _), do: {:error, :invalid_query}

  defp run(config, access, spec, now, generation) do
    started = System.monotonic_time()

    result =
      if valid?(config) do
        deadline = System.monotonic_time(:millisecond) + config.timeout
        recipient = Process.alias()
        caller = self()
        control = :atomics.new(1, [])
        query = {spec, generation}

        {worker, monitor} =
          spawn_monitor(fn ->
            worker(caller, recipient, control, config, access, query, now, deadline)
          end)

        try do
          await(worker, monitor, recipient, control, nil, deadline)
        after
          Process.unalias(recipient)
          Process.demonitor(monitor, [:flush])
        end
      else
        {:error, :invalid_query}
      end

    OperationalTelemetry.query(spec.aggregation, result, started)
    result
  end

  defp worker(caller, recipient, control, config, access, query, now, deadline) do
    result =
      with :ok <- rate(config.slots, access.principal),
           {:ok, lease} <- reserve(config.slots, access.principal) do
        try do
          execute(caller, recipient, control, config, access, query, now, deadline)
        after
          release(config.slots, access.principal, lease)
        end
      end

    result = if :atomics.get(control, 1) == 1, do: {:error, :deadline_exceeded}, else: result
    send(recipient, {recipient, :result, self(), result})
  end

  defp execute(caller, recipient, control, config, access, query, now, deadline) do
    with :ok <- config.fault.(:before_analytics),
         true <-
           Process.alive?(caller) and Process.alive?(config.store) and remaining(deadline) > 0 do
      open(caller, recipient, control, config, access, query, now, deadline)
    else
      false -> {:error, :deadline_exceeded}
      _ -> {:error, :storage_unavailable}
    end
  end

  defp open(caller, recipient, control, config, access, {spec, generation}, now, deadline) do
    case Sqlite3.open(config.path, mode: :readonly) do
      {:ok, db} ->
        watcher = watch(caller, config.store, self(), control, db, deadline)
        send(recipient, {recipient, :opened, self(), db})

        try do
          case config.fault.(:analytics_opened) do
            :ok ->
              SQL.boundary(fn ->
                SQL.checked(Sqlite3.set_busy_timeout(db, config.busy_timeout))
                SQL.checked(Sqlite3.set_progress_handler_steps(db, 100))
                SQL.execute!(db, "PRAGMA query_only=ON")
                require_schema!(db)

                Analytics.query(
                  db,
                  access.scope,
                  spec,
                  fn ->
                    Authority.check!(
                      db,
                      config.credentials,
                      access,
                      access.scope,
                      "read",
                      Authority.now(config, now)
                    )
                  end,
                  generation
                )
              end)

            _ ->
              {:error, :storage_unavailable}
          end
        after
          send(watcher, {:complete, self()})
          Sqlite3.close(db)
        end

      {:error, _} ->
        {:error, :storage_unavailable}
    end
  end

  defp watch(caller, store, worker, control, db, deadline) do
    spawn(fn ->
      caller_monitor = Process.monitor(caller)
      store_monitor = Process.monitor(store)
      worker_monitor = Process.monitor(worker)

      receive do
        {:complete, ^worker} ->
          :ok

        {:DOWN, ^caller_monitor, :process, ^caller, _} ->
          :atomics.put(control, 1, 1)
          cancel_until_stopped(db, worker, worker_monitor)

        {:DOWN, ^store_monitor, :process, ^store, _} ->
          :atomics.put(control, 1, 1)
          cancel_until_stopped(db, worker, worker_monitor)

        {:DOWN, ^worker_monitor, :process, ^worker, _} ->
          :ok
      after
        remaining(deadline) ->
          :atomics.put(control, 1, 1)
          cancel_until_stopped(db, worker, worker_monitor)
      end

      Process.demonitor(caller_monitor, [:flush])
      Process.demonitor(store_monitor, [:flush])
      Process.demonitor(worker_monitor, [:flush])
    end)
  end

  defp cancel_until_stopped(db, worker, monitor) do
    Sqlite3.cancel(db)

    receive do
      {:DOWN, ^monitor, :process, ^worker, _} -> :ok
    after
      1 -> cancel_until_stopped(db, worker, monitor)
    end
  end

  defp await(worker, monitor, recipient, control, db, deadline) do
    receive do
      {^recipient, :opened, ^worker, opened} ->
        await(worker, monitor, recipient, control, opened, deadline)

      {^recipient, :result, ^worker, result} ->
        result

      {:DOWN, ^monitor, :process, ^worker, _} ->
        {:error, :storage_unavailable}
    after
      remaining(deadline) ->
        :atomics.put(control, 1, 1)
        Sqlite3.cancel(db)
        await_cancel(worker, monitor)
        {:error, :deadline_exceeded}
    end
  end

  defp await_cancel(worker, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^worker, _} -> :ok
    after
      100 -> :ok
    end
  end

  defp rate(table, principal) do
    window = div(System.monotonic_time(:millisecond), @rate_window_ms)
    rate(table, {:rate, principal}, window)
  rescue
    ArgumentError -> {:error, :storage_unavailable}
  end

  defp rate(table, key, window) do
    case :ets.lookup(table, key) do
      [] ->
        if :ets.insert_new(table, {key, window, 1}),
          do: :ok,
          else: rate(table, key, window)

      [{^key, ^window, _}] ->
        if :ets.update_counter(table, key, {3, 1}) <= @rate_limit,
          do: :ok,
          else: {:error, :overloaded}

      [current] ->
        match = [{current, [], [{:const, {key, window, 1}}]}]
        if :ets.select_replace(table, match) == 1, do: :ok, else: rate(table, key, window)
    end
  end

  defp reserve(table, principal) do
    case slot(table, :global, @global_limit) do
      nil ->
        {:error, :overloaded}

      global ->
        case slot(table, {:principal, principal}, @principal_limit) do
          nil ->
            :ets.delete(table, {:active, :global, global})
            {:error, :overloaded}

          local ->
            {:ok, {global, local}}
        end
    end
  rescue
    ArgumentError -> {:error, :storage_unavailable}
  end

  defp slot(table, owner, limit) do
    Enum.find(1..limit, fn slot ->
      :ets.insert_new(table, {{:active, owner, slot}, self()})
    end)
  end

  defp release(table, principal, {global, local}) do
    :ets.delete(table, {:active, :global, global})
    :ets.delete(table, {:active, {:principal, principal}, local})
  rescue
    ArgumentError -> :ok
  end

  defp require_schema!(db) do
    case {SQL.rows!(db, "PRAGMA application_id"), SQL.rows!(db, "PRAGMA user_version")} do
      {[[1_465_143_857]], [[7]]} -> :ok
      _ -> throw({:storage, :unsupported_schema})
    end
  end

  defp valid?(%{
         path: path,
         store: store,
         slots: slots,
         timeout: timeout,
         busy_timeout: busy_timeout,
         credentials: _,
         clock: _,
         fault: fault
       }),
       do:
         is_binary(path) and is_pid(store) and is_reference(slots) and
           budgets?(timeout, busy_timeout) and
           is_function(fault, 1)

  defp valid?(_), do: false

  defp budgets?(timeout, busy_timeout)
       when is_integer(timeout) and timeout > 0 and is_integer(busy_timeout) and busy_timeout > 0,
       do: true

  defp budgets?(_, _), do: false

  defp remaining(deadline),
    do: max(deadline - System.monotonic_time(:millisecond), 0)
end
