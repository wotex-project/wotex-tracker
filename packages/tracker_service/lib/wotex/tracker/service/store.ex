defmodule Wotex.Tracker.Service.Store do
  @moduledoc """
  Explicitly supervised SQLite writer with atomic admission and historical reads.

  The returned handle is for trusted host code after authorization. It is not an
  authenticated client capability. Use the service API at untrusted boundaries.
  Calls reserve one of 32 slots before putting a prepared payload in the writer
  mailbox. A timed-out or dead caller does not cancel a possibly committed write;
  its bounded helper retains the slot until the store replies or dies.
  """
  use GenServer

  alias Exqlite.Sqlite3

  alias Wotex.Tracker.Service.{
    Access,
    Authority,
    Codec,
    Credentials,
    Operation,
    Publication,
    Read,
    Schema,
    SQL,
    StoreCall,
    StorePath,
    Transaction,
    Update
  }

  @enforce_keys [:pid, :slots, :timeout]
  defstruct [:pid, :slots, :timeout]
  @type t :: %__MODULE__{pid: pid(), slots: :ets.tid(), timeout: pos_integer()}

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
    {:reply, %__MODULE__{pid: self(), slots: state.slots, timeout: state.options.timeout}, state}
  end

  def handle_call(message, _from, state) do
    reply = SQL.boundary(fn -> dispatch(message, state) end)
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
        initialize(db, options)

      {:error, _} ->
        {:stop, :storage_unavailable}
    end
  end

  defp initialize(db, options) do
    case SQL.boundary(fn -> Schema.initialize(db, options) end) do
      :ok ->
        {:ok, %{db: db, options: options, slots: :ets.new(__MODULE__, [:public, :set])}}

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
      credentials: nil
    ]

    if Keyword.keyword?(options) and length(options) <= 7 and
         length(Keyword.keys(options)) == length(Enum.uniq(Keyword.keys(options))) and
         Enum.all?(Keyword.keys(options), &(&1 in [:directory | Keyword.keys(defaults)])) do
      validate_options(defaults |> Keyword.merge(options) |> Map.new(), defaults)
    else
      {:error, :invalid_options}
    end
  end

  defp validate_options(merged, defaults) do
    limits_valid =
      Enum.all?([:max_rows, :max_pages, :busy_timeout, :timeout], fn key ->
        is_integer(merged[key]) and merged[key] in 1..defaults[key]
      end)

    if Map.has_key?(merged, :directory) and limits_valid and is_function(merged.fault, 1) and
         valid_credentials?(merged.credentials),
       do: {:ok, merged},
       else: {:error, :invalid_options}
  end

  defp valid_credentials?(nil), do: true

  defp valid_credentials?(credentials), do: match?({:ok, _}, Credentials.validate(credentials))

  defp dispatch({:mutate, update}, state), do: Transaction.mutate(state.db, update, state.options)

  defp dispatch({:operation, scope, principal, id, now}, state),
    do: Transaction.operation(state.db, scope, principal, id, now)

  defp dispatch({:authorized_operation, access, id, now}, state) do
    SQL.execute!(state.db, "BEGIN")

    try do
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

  defp dispatch({:authorized_fetch, access, permission, query, now}, state),
    do:
      Read.fetch(state.db, query, fn ->
        Authority.check!(
          state.db,
          state.options.credentials,
          access,
          query.scope,
          permission,
          now
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
        now
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
          now
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
          query.now
        )
      end)

  defp dispatch({:publication, scope, thing, generation}, state),
    do: Publication.status(state.db, scope, thing, generation)

  defp dispatch({:latest_publication, scope, thing}, state),
    do: Publication.latest(state.db, scope, thing)

  defp dispatch({:confirm_publication, scope, thing, generation, cleanup}, state),
    do: Publication.confirm(state.db, scope, thing, generation, cleanup)

  defp dispatch(:readiness, state) do
    SQL.execute!(state.db, "BEGIN IMMEDIATE")

    try do
      SQL.rows!(state.db, "INSERT OR IGNORE INTO scopes VALUES('__readiness__',0)")
      [[version]] = SQL.rows!(state.db, "SELECT sqlite_version()")
      {:ok, %{"writable" => true, "schema" => "1", "sqlite" => version}}
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

  defp access_scope(%Access{scope: scope}), do: scope
  defp access_scope(_), do: nil
end
