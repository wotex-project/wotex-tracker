defmodule Wotex.Tracker.Service.Store do
  @moduledoc """
  Explicitly supervised SQLite writer with atomic admission and historical reads.

  The returned handle is for trusted host code after authorization. It is not an
  authenticated client capability. Use the service API at untrusted boundaries.
  Calls reserve one of 32 slots before putting a prepared payload in the writer
  mailbox. A timed-out or dead caller does not cancel a possibly committed write;
  its bounded helper retains the slot until the store replies or dies. Analytics
  uses separate cancellable read-only connections with tighter concurrency and
  per-principal start budgets.
  """
  use GenServer

  alias Exqlite.Sqlite3
  alias Wotex.Tracker.QuerySpec

  alias Wotex.Tracker.Service.{
    Access,
    AnalyticsCall,
    Authority,
    Codec,
    Credentials,
    ForwardItem,
    ForwardQueue,
    Operation,
    OperationalTelemetry,
    Publication,
    Read,
    RuleEvent,
    RuleStore,
    RuleTransition,
    Schema,
    SQL,
    StoreCall,
    StorePath,
    Transaction,
    Update
  }

  @derive {Inspect, only: [:pid, :timeout]}
  @enforce_keys [:pid, :slots, :timeout]
  defstruct [:pid, :slots, :timeout, :analytics]

  @type t :: %__MODULE__{
          pid: pid(),
          slots: :ets.tid(),
          timeout: pos_integer(),
          analytics: map() | nil
        }

  @doc "Starts a caller-owned store in an existing private absolute directory."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @doc "Obtains an instance handle without exposing its connection or data path."
  @spec handle(pid()) :: t()
  def handle(pid), do: GenServer.call(pid, :handle)

  @doc "Atomically commits an admitted host update; uncertainty never implies rollback."
  @spec mutate(t(), Update.t()) :: {:ok, map()} | {:error, atom()}
  def mutate(%__MODULE__{} = store, update) do
    with {:ok, admitted} <- Update.validate(update), do: StoreCall.run(store, {:mutate, admitted})
  end

  @doc "Looks up a retained caller-scoped operation without executing it again."
  @spec operation(t(), String.t(), String.t(), String.t(), integer()) ::
          {:ok, map()} | {:error, atom()}
  def operation(store, scope, principal, id, now) do
    if Enum.all?([scope, principal, id], &Codec.id?/1) and Codec.time?(now),
      do: StoreCall.run(store, {:operation, scope, principal, id, now}),
      else: {:error, :invalid_query}
  end

  @doc "Reads a caller-scoped receipt with current authority checked in the same read transaction."
  @spec authorized_operation(t(), Access.t(), String.t(), integer()) ::
          {:ok, map()} | {:error, atom()}
  def authorized_operation(store, access, id, now) do
    if Codec.id?(id) and Codec.time?(now),
      do: StoreCall.run(store, {:authorized_operation, access, id, now}),
      else: {:error, :invalid_query}
  end

  @doc "Checks a fully admitted intent before preparing new work; a new intent must still commit conditionally."
  @spec replay(t(), Access.t(), String.t(), map(), integer()) ::
          :new | {:ok, map()} | {:error, atom()}
  def replay(store, access, permission, intent, now) do
    if Operation.valid_intent?(intent),
      do: StoreCall.run(store, {:replay, access, permission, intent, now}),
      else: {:error, :invalid_request}
  end

  @doc "Reads one bounded page at a single immutable scope generation."
  @spec snapshot(t(), map()) :: {:ok, map()} | {:error, atom()}
  def snapshot(store, query), do: StoreCall.run(store, {:snapshot, query})

  @doc "Reads one exact record at a committed generation through the privileged host port."
  @spec fetch(t(), map()) :: {:ok, map()} | {:error, atom()}
  def fetch(store, query), do: StoreCall.run(store, {:fetch, query})

  @doc "Checks current scope authority and reads one exact historical record atomically."
  @spec authorized_fetch(t(), Access.t(), String.t(), map(), integer()) ::
          {:ok, map()} | {:error, atom()}
  def authorized_fetch(store, access, permission, query, now),
    do: StoreCall.run(store, {:authorized_fetch, access, permission, query, now})

  @doc "Reads a bounded durable event batch, rejecting expired or foreign cursors."
  @spec events(t(), map()) :: {:ok, map()} | {:error, atom()}
  def events(store, query), do: StoreCall.run(store, {:events, query})

  @doc "Checks current credential grants and durable revocation before a delivery."
  @spec authorized(t(), Access.t(), String.t(), integer()) :: :ok | {:error, atom()}
  def authorized(store, access, permission, now),
    do: StoreCall.run(store, {:authorized, access, permission, now})

  @doc "Checks current authority inside the same SQLite read snapshot as the requested page."
  @spec authorized_snapshot(t(), Access.t(), String.t(), map(), integer()) ::
          {:ok, map()} | {:error, atom()}
  def authorized_snapshot(store, access, permission, query, now),
    do: StoreCall.run(store, {:authorized_snapshot, access, permission, query, now})

  @doc "Runs one bounded analytics query inside a reauthorized immutable SQLite snapshot."
  @spec authorized_analytics(t(), Access.t(), QuerySpec.t(), integer()) ::
          {:ok, map()} | {:error, atom()}
  def authorized_analytics(store, access, spec, now) do
    with {:ok, admitted} <- QuerySpec.validate(spec),
         do: AnalyticsCall.run(store.analytics, access, admitted, now)
  end

  @doc false
  @spec authorized_analytics_at(t(), Access.t(), QuerySpec.t(), integer(), non_neg_integer()) ::
          {:ok, map()} | {:error, atom()}
  def authorized_analytics_at(store, access, spec, now, generation)
      when is_integer(generation) and generation >= 0 do
    with {:ok, admitted} <- QuerySpec.validate(spec),
         do: AnalyticsCall.run_at(store.analytics, access, admitted, now, generation)
  end

  def authorized_analytics_at(_, _, _, _, _), do: {:error, :invalid_query}

  @doc "Reads bounded ascending record versions, retaining explicit deletion tombstones."
  @spec history(t(), map()) :: {:ok, map()} | {:error, atom()}
  def history(store, query), do: StoreCall.run(store, {:history, query})

  @doc "Reauthorizes record history inside the same immutable SQLite read snapshot."
  @spec authorized_history(t(), Access.t(), map(), integer()) :: {:ok, map()} | {:error, atom()}
  def authorized_history(store, access, query, now),
    do: StoreCall.run(store, {:authorized_history, access, query, now})

  @doc "Reauthorizes resumed event reads inside their database snapshot."
  @spec authorized_events(t(), Access.t(), map()) :: {:ok, map()} | {:error, atom()}
  def authorized_events(store, access, query),
    do: StoreCall.run(store, {:authorized_events, access, query})

  @doc "Checks actual write access using a rolled-back SQLite transaction."
  @spec readiness(t()) :: {:ok, map()} | {:error, atom()}
  def readiness(store), do: StoreCall.run(store, :readiness)

  @doc "Runs a passive WAL checkpoint and reports busy/remaining pages."
  @spec checkpoint(t()) :: {:ok, map()} | {:error, atom()}
  def checkpoint(store), do: StoreCall.run(store, :checkpoint)

  @doc "Creates a SQLite-consistent backup at a new path in a private directory."
  @spec backup(t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def backup(store, path) do
    with :ok <- StorePath.backup_target(path), do: StoreCall.run(store, {:backup, path})
  end

  @doc "Returns an exact publication intent and its independent effect/cleanup status."
  @spec publication(t(), String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def publication(store, scope, thing, generation),
    do: StoreCall.run(store, {:publication, scope, thing, generation})

  @doc "Gets only the latest Thing publication; external effects require conditional remote writes."
  @spec latest_publication(t(), String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def latest_publication(store, scope, thing),
    do: StoreCall.run(store, {:latest_publication, scope, thing})

  @doc "Records reconciled remote success; stale confirmations cannot replace the latest generation."
  @spec confirm_publication(t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, atom()}
  def confirm_publication(store, scope, thing, generation, cleanup),
    do: StoreCall.run(store, {:confirm_publication, scope, thing, generation, cleanup})

  @doc "Durably admits one bounded item or records a lossy overflow disposition."
  @spec enqueue_forward(t(), ForwardItem.t()) :: {:ok, map()} | {:error, atom()}
  def enqueue_forward(store, item) do
    with {:ok, admitted} <- ForwardItem.validate(item),
         do: StoreCall.run(store, {:enqueue_forward, admitted})
  end

  @doc "Claims due items in stable FIFO order and durably advances their attempt budget."
  @spec claim_forward(t(), String.t(), integer(), pos_integer(), pos_integer()) ::
          {:ok, map()} | {:error, atom()}
  def claim_forward(store, scope, now, limit, retry_after_ms) do
    if Codec.id?(scope) and Codec.time?(now) and is_integer(limit) and limit in 1..100 and
         is_integer(retry_after_ms) and retry_after_ms in 1..86_400_000,
       do: StoreCall.run(store, {:claim_forward, scope, now, limit, retry_after_ms}),
       else: {:error, :invalid_query}
  end

  @doc "Returns one durable queue receipt without changing retry or expiry state."
  @spec forward_status(t(), String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def forward_status(store, scope, id) do
    if Codec.id?(scope) and Codec.id?(id),
      do: StoreCall.run(store, {:forward_status, scope, id}),
      else: {:error, :invalid_query}
  end

  @doc "Records exact send or layered acknowledgement evidence idempotently."
  @spec complete_forward(t(), String.t(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, atom()}
  def complete_forward(store, scope, id, identity, completion) do
    with true <- Codec.id?(scope) and Codec.id?(id) and Codec.id?(identity),
         {:ok, completion} <- ForwardQueue.completion(completion) do
      StoreCall.run(store, {:complete_forward, scope, id, identity, completion})
    else
      _ -> {:error, :invalid_query}
    end
  end

  @doc "Explicitly removes terminal queue receipts settled at or before a cutoff."
  @spec cleanup_forward(t(), String.t(), integer()) :: {:ok, map()} | {:error, atom()}
  def cleanup_forward(store, scope, before) do
    if Codec.id?(scope) and Codec.time?(before),
      do: StoreCall.run(store, {:cleanup_forward, scope, before}),
      else: {:error, :invalid_query}
  end

  @doc "Atomically advances validated rule state and records its stable event intent."
  @spec commit_rule(t(), RuleTransition.t()) :: {:ok, map()} | {:error, atom()}
  def commit_rule(store, transition) do
    with {:ok, admitted} <- RuleTransition.validate(transition),
         do: StoreCall.run(store, {:commit_rule, admitted})
  end

  @doc "Atomically records one re-evaluated event-only rule intent and public event."
  @spec commit_rule_event(t(), RuleEvent.t()) :: {:ok, map()} | {:error, atom()}
  def commit_rule_event(store, intent) do
    with {:ok, admitted} <- RuleEvent.validate(intent),
         do: StoreCall.run(store, {:commit_rule_event, admitted})
  end

  @doc "Reads one canonical durable rule state through the privileged host port."
  @spec rule_state(t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, atom()}
  def rule_state(store, scope, kind, rule_id) do
    if Enum.all?([scope, kind, rule_id], &Codec.id?/1),
      do: StoreCall.run(store, {:rule_state, scope, kind, rule_id}),
      else: {:error, :invalid_query}
  end

  @doc "Reads one deduplicated durable rule event intent."
  @spec rule_event(t(), String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def rule_event(store, scope, event_id) do
    if Codec.id?(scope) and Codec.id?(event_id),
      do: StoreCall.run(store, {:rule_event, scope, event_id}),
      else: {:error, :invalid_query}
  end

  @doc "Reads the bounded time-driven rule states owned by a trusted scheduler."
  @spec scheduled_rules(t(), pos_integer()) :: {:ok, [map()]} | {:error, atom()}
  def scheduled_rules(store, limit) when is_integer(limit) and limit in 1..1_024,
    do: StoreCall.run(store, {:scheduled_rules, limit})

  def scheduled_rules(_, _), do: {:error, :invalid_query}

  @impl true
  def init(options) do
    with {:ok, options} <- options(options),
         {:ok, path} <- StorePath.database(options.directory) do
      open(path, options)
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:handle, _from, state) do
    analytics = %{
      path: state.path,
      store: self(),
      slots: state.analytics_slots,
      timeout: state.options.timeout,
      busy_timeout: state.options.busy_timeout,
      credentials: state.options.credentials,
      clock: state.options.clock,
      fault: state.options.fault
    }

    {:reply,
     %__MODULE__{
       pid: self(),
       slots: state.slots,
       timeout: state.options.timeout,
       analytics: analytics
     }, state}
  end

  def handle_call(message, _from, state) do
    started = System.monotonic_time()
    reply = SQL.boundary(fn -> dispatch(message, state) end)
    emit_call(message, reply, state, started)
    {:reply, reply, state}
  end

  @impl true
  def terminate(_reason, state), do: Sqlite3.close(state.db)

  @impl true
  def format_status(status),
    do: Map.merge(status, %{state: :redacted, message: :redacted, reason: :redacted})

  defp open(path, options) do
    case Sqlite3.open(path, mode: :readwrite) do
      {:ok, db} ->
        initialize(db, path, options)

      {:error, _} ->
        {:stop, :storage_unavailable}
    end
  end

  defp initialize(db, path, options) do
    case SQL.boundary(fn -> Schema.initialize(db, options) end) do
      :ok ->
        {:ok,
         %{
           db: db,
           path: path,
           options: options,
           slots: :ets.new(__MODULE__, [:public, :set]),
           analytics_slots: :ets.new(AnalyticsCall, [:public, :set, write_concurrency: true])
         }}

      {:error, reason} ->
        Sqlite3.close(db)
        {:stop, reason}
    end
  end

  defp options(options) do
    defaults = [
      max_rows: 100_000,
      max_pages: 262_144,
      busy_timeout: 1000,
      timeout: 5000,
      fault: fn _ -> :ok end,
      credentials: nil,
      clock: nil,
      forward_max_items: 1024,
      forward_max_bytes: 16_777_216,
      forward_max_age_ms: 604_800_000,
      forward_max_attempts: 8
    ]

    if Keyword.keyword?(options) and length(options) <= 12 and
         length(Keyword.keys(options)) == length(Enum.uniq(Keyword.keys(options))) and
         Enum.all?(Keyword.keys(options), &(&1 in [:directory | Keyword.keys(defaults)])) do
      validate_options(defaults |> Keyword.merge(options) |> Map.new(), defaults)
    else
      {:error, :invalid_options}
    end
  end

  defp validate_options(merged, defaults) do
    maxima = %{
      max_rows: defaults[:max_rows],
      max_pages: defaults[:max_pages],
      busy_timeout: defaults[:busy_timeout],
      timeout: defaults[:timeout],
      forward_max_items: defaults[:forward_max_items],
      forward_max_bytes: defaults[:forward_max_bytes],
      forward_max_age_ms: defaults[:forward_max_age_ms],
      forward_max_attempts: defaults[:forward_max_attempts]
    }

    limits_valid =
      Enum.all?(maxima, fn {key, maximum} ->
        is_integer(merged[key]) and merged[key] in 1..maximum
      end)

    if Map.has_key?(merged, :directory) and limits_valid and is_function(merged.fault, 1) and
         valid_credentials?(merged.credentials) and
         (is_nil(merged.clock) or is_function(merged.clock, 0)),
       do: {:ok, merged},
       else: {:error, :invalid_options}
  end

  defp valid_credentials?(nil), do: true

  defp valid_credentials?(credentials), do: match?({:ok, _}, Credentials.validate(credentials))

  defp dispatch({:mutate, update}, state), do: Transaction.mutate(state.db, update, state.options)

  defp dispatch({:operation, scope, principal, id, now}, state),
    do: Transaction.operation(state.db, scope, principal, id, Authority.now(state.options, now))

  defp dispatch({:authorized_operation, access, id, now}, state) do
    SQL.execute!(state.db, "BEGIN")

    try do
      now = Authority.now(state.options, now)

      Authority.check!(
        state.db,
        state.options.credentials,
        access,
        access_scope(access),
        "read",
        now
      )

      Transaction.operation(state.db, access.scope, access.principal, id, now)
    after
      SQL.rollback(state.db)
    end
  end

  defp dispatch({:replay, access, permission, intent, now}, state) do
    SQL.execute!(state.db, "BEGIN")

    try do
      now = Authority.now(state.options, now)

      Authority.check!(
        state.db,
        state.options.credentials,
        access,
        access_scope(access),
        permission,
        now
      )

      digest =
        Operation.digest(intent.request, intent.expected_generation, intent.observation_identity)

      Operation.lookup(state.db, access.scope, access.principal, intent.operation_id, digest, now)
    after
      SQL.rollback(state.db)
    end
  end

  defp dispatch({:snapshot, query}, state), do: Read.snapshot(state.db, query)
  defp dispatch({:fetch, query}, state), do: Read.fetch(state.db, query)
  defp dispatch({:history, query}, state), do: Read.history(state.db, query)

  defp dispatch({:authorized_history, access, query, now}, state),
    do:
      Read.history(state.db, query, fn ->
        Authority.check!(
          state.db,
          state.options.credentials,
          access,
          query.scope,
          "read",
          Authority.now(state.options, now)
        )
      end)

  defp dispatch({:authorized_fetch, access, permission, query, now}, state),
    do:
      Read.fetch(state.db, query, fn ->
        Authority.check!(
          state.db,
          state.options.credentials,
          access,
          query.scope,
          permission,
          Authority.now(state.options, now)
        )
      end)

  defp dispatch({:events, query}, state), do: Read.events(state.db, query)

  defp dispatch({:authorized, access, permission, now}, state),
    do:
      Authority.check!(
        state.db,
        state.options.credentials,
        access,
        access_scope(access),
        permission,
        Authority.now(state.options, now)
      )

  defp dispatch({:authorized_snapshot, access, permission, query, now}, state),
    do:
      Read.snapshot(state.db, query, fn ->
        Authority.check!(
          state.db,
          state.options.credentials,
          access,
          query.scope,
          permission,
          Authority.now(state.options, now)
        )
      end)

  defp dispatch({:authorized_events, access, query}, state),
    do:
      Read.events(state.db, query, fn ->
        Authority.check!(
          state.db,
          state.options.credentials,
          access,
          query.scope,
          "read",
          Authority.now(state.options, query.now)
        )
      end)

  defp dispatch({:publication, scope, thing, generation}, state),
    do: Publication.status(state.db, scope, thing, generation)

  defp dispatch({:latest_publication, scope, thing}, state),
    do: Publication.latest(state.db, scope, thing)

  defp dispatch({:confirm_publication, scope, thing, generation, cleanup}, state),
    do: Publication.confirm(state.db, scope, thing, generation, cleanup)

  defp dispatch({:enqueue_forward, item}, state),
    do: ForwardQueue.enqueue(state.db, item, state.options)

  defp dispatch({:claim_forward, scope, now, limit, retry_after_ms}, state),
    do: ForwardQueue.claim(state.db, scope, now, limit, retry_after_ms, state.options)

  defp dispatch({:forward_status, scope, id}, state),
    do: ForwardQueue.status(state.db, scope, id)

  defp dispatch({:complete_forward, scope, id, identity, completion}, state),
    do: ForwardQueue.complete(state.db, scope, id, identity, completion, state.options)

  defp dispatch({:cleanup_forward, scope, before}, state),
    do: ForwardQueue.cleanup(state.db, scope, before, state.options)

  defp dispatch({:commit_rule, transition}, state),
    do: RuleStore.commit(state.db, transition, state.options)

  defp dispatch({:commit_rule_event, intent}, state),
    do: RuleStore.commit_event(state.db, intent, state.options)

  defp dispatch({:rule_state, scope, kind, rule_id}, state),
    do: RuleStore.status(state.db, scope, kind, rule_id)

  defp dispatch({:rule_event, scope, event_id}, state),
    do: RuleStore.event(state.db, scope, event_id)

  defp dispatch({:scheduled_rules, limit}, state),
    do: RuleStore.scheduled(state.db, limit)

  defp dispatch(:readiness, state) do
    SQL.execute!(state.db, "BEGIN IMMEDIATE")

    try do
      SQL.rows!(state.db, "INSERT OR IGNORE INTO scopes VALUES('__readiness__',0)")
      [[version]] = SQL.rows!(state.db, "SELECT sqlite_version()")
      {:ok, %{"writable" => true, "schema" => "3", "sqlite" => version}}
    after
      SQL.rollback(state.db)
    end
  end

  defp dispatch(:checkpoint, state) do
    [[busy, log, checkpointed]] = SQL.rows!(state.db, "PRAGMA wal_checkpoint(PASSIVE)")
    {:ok, %{"busy" => busy, "pages" => log, "checkpointed" => checkpointed}}
  end

  defp dispatch({:backup, path}, state) do
    with :ok <- StorePath.backup_target(path) do
      SQL.rows!(state.db, "VACUUM main INTO ?", [path])

      case File.chmod(path, 0o600) do
        :ok -> {:ok, %{"backup" => "complete"}}
        {:error, _} -> {:error, :backup_permissions}
      end
    end
  end

  defp emit_call({:mutate, _}, result, _state, started),
    do: OperationalTelemetry.store(:mutation, result, started)

  defp emit_call({:commit_rule, _}, result, _state, started),
    do: OperationalTelemetry.store(:rule_state, result, started)

  defp emit_call({:commit_rule_event, _}, result, _state, started),
    do: OperationalTelemetry.store(:rule_event, result, started)

  defp emit_call({:enqueue_forward, item}, result, state, started),
    do: emit_queue(:enqueue, item.scope, result, state, started)

  defp emit_call({:claim_forward, scope, _, _, _}, result, state, started),
    do: emit_queue(:claim, scope, result, state, started)

  defp emit_call({:complete_forward, scope, _, _, _}, result, state, started),
    do: emit_queue(:complete, scope, result, state, started)

  defp emit_call({:cleanup_forward, scope, _}, result, state, started),
    do: emit_queue(:cleanup, scope, result, state, started)

  defp emit_call({:publication, _, _, _}, result, _state, started),
    do: OperationalTelemetry.publication(:lookup, result, started)

  defp emit_call({:latest_publication, _, _}, result, _state, started),
    do: OperationalTelemetry.publication(:latest, result, started)

  defp emit_call({:confirm_publication, _, _, _, _}, result, _state, started),
    do: OperationalTelemetry.publication(:confirm, result, started)

  defp emit_call(:readiness, result, _state, started),
    do: OperationalTelemetry.resource(:store, :readiness, result, started)

  defp emit_call(:checkpoint, result, _state, started),
    do: OperationalTelemetry.resource(:store, :checkpoint, result, started)

  defp emit_call({:backup, _}, result, _state, started),
    do: OperationalTelemetry.resource(:store, :backup, result, started)

  defp emit_call(_, _, _, _), do: :ok

  defp emit_queue(operation, scope, result, state, started) do
    case SQL.boundary(fn -> ForwardQueue.metrics(state.db, scope) end) do
      %{depth_items: _, depth_bytes: _} = depth ->
        OperationalTelemetry.queue(
          operation,
          result,
          Map.merge(depth, queue_effects(operation, result)),
          started
        )

      _ ->
        :ok
    end
  end

  defp queue_effects(:enqueue, {:ok, %{"disposition" => disposition}}),
    do: %{affected_items: 1, dropped_items: if(disposition == "dropped", do: 1, else: 0)}

  defp queue_effects(:claim, {:ok, %{"items" => items}}),
    do: %{affected_items: length(items), dropped_items: 0}

  defp queue_effects(:complete, {:ok, _}), do: %{affected_items: 1, dropped_items: 0}

  defp queue_effects(:cleanup, {:ok, %{"removed" => removed}}),
    do: %{affected_items: removed, dropped_items: 0}

  defp queue_effects(_, _), do: %{affected_items: 0, dropped_items: 0}

  defp access_scope(%Access{scope: scope}), do: scope
  defp access_scope(_), do: nil
end
