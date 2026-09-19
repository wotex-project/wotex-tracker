defmodule Wotex.Tracker.Mobile.Cache do
  @moduledoc """
  Bounded, account-isolated storage for offline presentation projections.

  This cache is not an authority source. It accepts only the closed overview,
  history, dashboard and map projection classes, stores no bearer credential or
  pending mutation, and returns explicit synchronization age and completeness.
  Changing server/account/scope/installation binding purges every retained row.
  """

  use GenServer
  import Bitwise

  alias Exqlite.Sqlite3

  @account_schema "wtr.mobile-account.v1"
  @cache_schema "wtr.mobile-cache.v1"
  @database "mobile-cache.sqlite3"
  @kinds ~w(overview history dashboard map)
  @maximum_integer 9_007_199_254_740_991
  @option_keys ~w(directory max_entries max_bytes max_entry_bytes max_age_ms name)a
  @secret_words ~w(authorization bearer cookie credential csrf password proof raw secret token)

  @derive {Inspect, only: [:path, :max_entries, :max_bytes, :max_entry_bytes, :max_age_ms]}
  defstruct [
    :db,
    :path,
    :account,
    :expires_at,
    :max_entries,
    :max_bytes,
    :max_entry_bytes,
    :max_age_ms
  ]

  @type account :: %{required(String.t()) => String.t() | non_neg_integer()}

  @type projection_kind :: :overview | :history | :dashboard | :map

  @doc "Starts one serialized cache over an app-private directory."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) when is_list(options) do
    GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name]))
  end

  @doc "Binds the cache to one remotely authenticated account projection."
  @spec bind(GenServer.server(), account(), non_neg_integer()) :: :ok | {:error, atom()}
  def bind(cache, account, now), do: GenServer.call(cache, {:bind, account, now})

  @doc "Stores one authorized presentation projection and enforces all limits."
  @spec put(
          GenServer.server(),
          account(),
          projection_kind(),
          String.t(),
          map() | list(),
          non_neg_integer(),
          boolean(),
          non_neg_integer()
        ) :: :ok | {:error, atom()}
  def put(cache, account, kind, key, projection, synchronized_at, complete, now) do
    GenServer.call(
      cache,
      {:put, account, kind, key, projection, synchronized_at, complete, now}
    )
  end

  @doc "Reads one offline projection under the same non-secret account binding."
  @spec read(GenServer.server(), account(), projection_kind(), String.t(), non_neg_integer()) ::
          {:ok, map()} | {:error, atom()}
  def read(cache, account, kind, key, now) do
    GenServer.call(cache, {:read, account, kind, key, now})
  end

  @doc "Reports bounded cache occupancy without returning an account fingerprint."
  @spec status(GenServer.server(), account(), non_neg_integer()) ::
          {:ok, map()} | {:error, atom()}
  def status(cache, account, now), do: GenServer.call(cache, {:status, account, now})

  @doc "Purges all projections and the persisted account binding."
  @spec purge(GenServer.server()) :: :ok | {:error, :cache_unavailable}
  def purge(cache), do: GenServer.call(cache, :purge)

  @impl true
  def init(options) do
    with {:ok, config} <- configuration(options),
         {:ok, path} <- database(config.directory),
         {:ok, db} <- Sqlite3.open(path) do
      initialize_open_database(db, path, config)
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:bind, input, now}, _from, state) do
    with {:ok, account} <- account(input),
         :ok <- timestamp(now) do
      if account.expires_at <= now do
        reply_clear(state, {:error, :expired})
      else
        bind_account(state, account, now)
      end
    else
      _ -> {:reply, {:error, :invalid_account}, state}
    end
  end

  def handle_call({:put, input, kind, key, projection, synchronized_at, complete, now}, _, state) do
    with {:ok, account} <- admitted(state, input, now),
         {:ok, kind} <- kind(kind),
         :ok <- key(key),
         :ok <- timestamp(synchronized_at),
         true <- synchronized_at <= now,
         true <- is_boolean(complete),
         {:ok, payload} <- projection(projection, state.max_entry_bytes) do
      write(state, account, kind, key, payload, synchronized_at, complete, now)
    else
      false -> {:reply, {:error, :invalid_projection}, state}
      {:error, reason} -> account_error(state, input, reason)
    end
  end

  def handle_call({:read, input, kind, key, now}, _, state) do
    with {:ok, account} <- admitted(state, input, now),
         {:ok, kind} <- kind(kind),
         :ok <- key(key) do
      read_projection(state, account, kind, key, now)
    else
      {:error, reason} -> account_error(state, input, reason)
    end
  end

  def handle_call({:status, input, now}, _, state) do
    case admitted(state, input, now) do
      {:ok, account} -> cache_status(state, account, now)
      {:error, reason} -> account_error(state, input, reason)
    end
  end

  def handle_call(:purge, _from, state), do: reply_clear(state, :ok)

  @impl true
  def terminate(_reason, %{db: db}) do
    _ = Sqlite3.close(db)
    :ok
  end

  defp configuration(options) do
    with true <- Keyword.keyword?(options),
         true <- length(options) == map_size(Map.new(options)),
         [] <- Keyword.keys(options) -- @option_keys,
         directory when is_binary(directory) <- Keyword.get(options, :directory),
         max_entries <- Keyword.get(options, :max_entries, 256),
         true <- is_integer(max_entries) and max_entries in 1..1_000,
         max_bytes <- Keyword.get(options, :max_bytes, 16_777_216),
         true <- is_integer(max_bytes) and max_bytes in 1_024..67_108_864,
         max_entry_bytes <- Keyword.get(options, :max_entry_bytes, 1_048_576),
         true <- is_integer(max_entry_bytes) and max_entry_bytes in 256..max_bytes,
         max_age_ms <- Keyword.get(options, :max_age_ms, 604_800_000),
         true <- is_integer(max_age_ms) and max_age_ms in 100..2_678_400_000 do
      {:ok,
       %{
         directory: directory,
         max_entries: max_entries,
         max_bytes: max_bytes,
         max_entry_bytes: max_entry_bytes,
         max_age_ms: max_age_ms
       }}
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  defp database(directory) do
    path = Path.join(directory, @database)

    with :ok <- private_directory(directory),
         :ok <- regular_or_missing(path),
         :ok <- create_private(path) do
      {:ok, path}
    end
  end

  defp private_directory(directory)
       when is_binary(directory) and byte_size(directory) in 1..4_096 do
    with true <- Path.type(directory) == :absolute and Path.expand(directory) == directory,
         true <- no_symlinks?(directory),
         {:ok, stat} <- File.lstat(directory),
         true <- stat.type == :directory and (stat.mode &&& 0o077) == 0 do
      :ok
    else
      _ -> {:error, :unsafe_path}
    end
  end

  defp private_directory(_), do: {:error, :unsafe_path}

  defp no_symlinks?(directory) do
    directory
    |> Path.split()
    |> Enum.scan(&Path.join(&2, &1))
    |> Enum.all?(fn path -> match?({:ok, %{type: :directory}}, File.lstat(path)) end)
  end

  defp regular_or_missing(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular, links: 1, mode: mode}} when (mode &&& 0o077) == 0 -> :ok
      {:error, :enoent} -> :ok
      _ -> {:error, :unsafe_path}
    end
  end

  defp create_private(path) do
    case File.open(path, [:write, :exclusive]) do
      {:ok, file} ->
        with :ok <- File.close(file), do: File.chmod(path, 0o600)

      {:error, :eexist} ->
        :ok

      {:error, _} ->
        {:error, :cache_unavailable}
    end
  end

  defp initialize(db) do
    safely(fn ->
      execute!(db, "PRAGMA journal_mode = DELETE")
      execute!(db, "PRAGMA synchronous = FULL")
      execute!(db, "PRAGMA foreign_keys = ON")
      execute!(db, "PRAGMA secure_delete = ON")
      execute!(db, "PRAGMA busy_timeout = 100")

      case rows!(db, "PRAGMA user_version") do
        [[0]] -> create_schema!(db)
        [[1]] -> validate_schema!(db)
        _ -> throw({:cache, :unsupported_cache})
      end

      :ok
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp initialize_open_database(db, path, config) do
    result =
      with :ok <- initialize(db),
           {:ok, account, expires_at} <- stored_binding(db) do
        state =
          struct!(
            __MODULE__,
            config |> Map.delete(:directory) |> Map.merge(%{db: db, path: path})
          )

        ready_state(%{state | account: account, expires_at: expires_at})
      end

    case result do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> close(db, {:stop, reason})
    end
  end

  defp ready_state(state) do
    case safely(fn -> evict!(state) end) do
      {:ok, :ok} -> {:ok, state}
      {:error, _} -> {:error, :cache_unavailable}
    end
  end

  defp create_schema!(db) do
    transaction!(db, fn ->
      execute!(
        db,
        """
        CREATE TABLE metadata (
          singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
          schema TEXT NOT NULL,
          account TEXT,
          expires_at INTEGER
        ) STRICT
        """
      )

      execute!(
        db,
        """
        CREATE TABLE projections (
          account TEXT NOT NULL,
          kind TEXT NOT NULL,
          cache_key TEXT NOT NULL,
          payload BLOB NOT NULL,
          synchronized_at INTEGER NOT NULL,
          complete INTEGER NOT NULL CHECK (complete IN (0, 1)),
          bytes INTEGER NOT NULL CHECK (bytes >= 0),
          touched_at INTEGER NOT NULL,
          PRIMARY KEY (account, kind, cache_key)
        ) WITHOUT ROWID, STRICT
        """
      )

      execute!(db, "INSERT INTO metadata VALUES (1, '#{@cache_schema}', NULL, NULL)")
      execute!(db, "PRAGMA user_version = 1")
    end)
  end

  defp validate_schema!(db) do
    with [["ok"]] <- rows!(db, "PRAGMA quick_check"),
         [[@cache_schema]] <- rows!(db, "SELECT schema FROM metadata WHERE singleton = 1"),
         true <- table_columns(db, "metadata") == ~w(singleton schema account expires_at),
         true <-
           table_columns(db, "projections") ==
             ~w(account kind cache_key payload synchronized_at complete bytes touched_at) do
      :ok
    else
      _ -> throw({:cache, :unsupported_cache})
    end
  end

  defp table_columns(db, table) do
    db
    |> rows!("PRAGMA table_info(#{table})")
    |> Enum.map(fn [_, name, _, _, _, _] -> name end)
  end

  defp stored_binding(db) do
    safely(fn ->
      case rows!(db, "SELECT account, expires_at FROM metadata WHERE singleton = 1") do
        [[nil, nil]] ->
          {nil, nil}

        [[account, expires_at]] when is_binary(account) and is_integer(expires_at) ->
          {account, expires_at}

        _ ->
          throw({:cache, :cache_unavailable})
      end
    end)
    |> case do
      {:ok, {account, expires_at}} -> {:ok, account, expires_at}
      {:error, reason} -> {:error, reason}
    end
  end

  defp account(
         %{
           "schema" => @account_schema,
           "origin" => origin,
           "principal" => principal,
           "scope" => scope,
           "credential_id" => credential,
           "installation_id" => installation,
           "expires_at" => expires_at
         } = account
       )
       when map_size(account) == 7 do
    with {:ok, origin} <- origin(origin),
         true <- Enum.all?([principal, scope, credential, installation], &identifier?/1),
         :ok <- timestamp(expires_at) do
      material =
        [@account_schema, origin, principal, scope, credential, installation]
        |> Enum.map_join(fn value -> <<byte_size(value)::unsigned-big-32, value::binary>> end)

      {:ok,
       %{
         fingerprint: Base.url_encode64(:crypto.hash(:sha256, material), padding: false),
         expires_at: expires_at
       }}
    else
      _ -> {:error, :invalid_account}
    end
  end

  defp account(_), do: {:error, :invalid_account}

  defp origin(value) when is_binary(value) do
    uri = URI.parse(value)

    with "https" <- uri.scheme,
         host when is_binary(host) and host != "" <- uri.host,
         true <- is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment),
         true <- uri.path in [nil, ""],
         port when port in 1..65_535 <- uri.port || 443 do
      normalized =
        URI.to_string(%URI{
          scheme: "https",
          host: String.downcase(host),
          port: if(port == 443, do: nil, else: port)
        })

      if value == normalized, do: {:ok, normalized}, else: {:error, :invalid_account}
    else
      _ -> {:error, :invalid_account}
    end
  end

  defp origin(_), do: {:error, :invalid_account}

  defp bind_account(state, account, now) do
    case safely(fn -> persist_binding!(state, account, now) end) do
      {:ok, :ok} ->
        {:reply, :ok, %{state | account: account.fingerprint, expires_at: account.expires_at}}

      {:error, _} ->
        {:reply, {:error, :cache_unavailable}, state}
    end
  end

  defp persist_binding!(state, account, now) do
    transaction!(state.db, fn ->
      if state.account != account.fingerprint,
        do: execute!(state.db, "DELETE FROM projections")

      expire_stale!(state, now)

      run!(
        state.db,
        "UPDATE metadata SET account = ?, expires_at = ? WHERE singleton = 1",
        [account.fingerprint, account.expires_at]
      )
    end)
  end

  defp admitted(state, input, now) do
    with {:ok, account} <- account(input),
         :ok <- timestamp(now),
         true <- state.account == account.fingerprint,
         true <- is_integer(state.expires_at) do
      if now < min(account.expires_at, state.expires_at),
        do: {:ok, account},
        else: {:error, :expired}
    else
      false -> {:error, :account_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp account_error(state, _input, :expired), do: reply_clear(state, {:error, :expired})

  defp account_error(state, _input, reason), do: {:reply, {:error, reason}, state}

  defp write(state, account, kind, key, payload, synchronized_at, complete, now) do
    case safely(fn ->
           persist_projection!(state, account, kind, key, payload, synchronized_at, complete, now)
         end) do
      {:ok, :ok} -> {:reply, :ok, state}
      {:error, _} -> {:reply, {:error, :cache_unavailable}, state}
    end
  end

  defp persist_projection!(state, account, kind, key, payload, synchronized_at, complete, now) do
    transaction!(state.db, fn ->
      expire_stale!(state, now)

      run!(
        state.db,
        """
        INSERT INTO projections
          (account, kind, cache_key, payload, synchronized_at, complete, bytes, touched_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (account, kind, cache_key) DO UPDATE SET
          payload = excluded.payload,
          synchronized_at = excluded.synchronized_at,
          complete = excluded.complete,
          bytes = excluded.bytes,
          touched_at = excluded.touched_at
        """,
        [
          account.fingerprint,
          kind,
          key,
          {:blob, payload},
          synchronized_at,
          if(complete, do: 1, else: 0),
          byte_size(payload),
          now
        ]
      )

      evict!(state)
    end)
  end

  defp read_projection(state, account, kind, key, now) do
    case safely(fn ->
           rows!(
             state.db,
             """
             SELECT payload, synchronized_at, complete
             FROM projections
             WHERE account = ? AND kind = ? AND cache_key = ?
             """,
             [account.fingerprint, kind, key]
           )
         end) do
      {:ok, []} ->
        {:reply, {:error, :cache_miss}, state}

      {:ok, [[payload, synchronized_at, complete]]} ->
        project_row(state, account, kind, key, payload, synchronized_at, complete, now)

      {:ok, _} ->
        {:reply, {:error, :cache_unavailable}, state}

      {:error, _} ->
        {:reply, {:error, :cache_unavailable}, state}
    end
  end

  defp project_row(state, account, kind, key, payload, synchronized_at, complete, now) do
    age = max(now - synchronized_at, 0)

    if age > state.max_age_ms do
      delete_projection(state, account.fingerprint, kind, key, {:error, :cache_miss})
    else
      context = %{
        account: account,
        kind: kind,
        key: key,
        synchronized_at: synchronized_at,
        complete: complete,
        now: now,
        age: age
      }

      decode_row(state, payload, context)
    end
  end

  defp decode_row(state, payload, context) do
    case Jason.decode(payload) do
      {:ok, projection} when is_map(projection) or is_list(projection) ->
        present_row(state, projection, context)

      _ ->
        delete_projection(
          state,
          context.account.fingerprint,
          context.kind,
          context.key,
          {:error, :cache_unavailable}
        )
    end
  end

  defp present_row(state, projection, context) do
    result = %{
      "schema" => @cache_schema,
      "source" => "offline_cache",
      "kind" => context.kind,
      "key" => context.key,
      "projection" => projection,
      "synchronized_at" => context.synchronized_at,
      "age_ms" => context.age,
      "complete" => context.complete == 1,
      "expires_at" => min(context.account.expires_at, state.expires_at)
    }

    case safely(fn ->
           touch!(
             state.db,
             context.account.fingerprint,
             context.kind,
             context.key,
             context.now
           )
         end) do
      {:ok, :ok} -> {:reply, {:ok, result}, state}
      {:error, _} -> {:reply, {:error, :cache_unavailable}, state}
    end
  end

  defp cache_status(state, account, now) do
    case safely(fn ->
           expire_stale!(state, now)

           rows!(
             state.db,
             """
             SELECT COUNT(*), COALESCE(SUM(bytes), 0), MIN(synchronized_at), MAX(synchronized_at)
             FROM projections WHERE account = ?
             """,
             [account.fingerprint]
           )
         end) do
      {:ok, [[entries, bytes, oldest, newest]]} ->
        {:reply,
         {:ok,
          %{
            "schema" => @cache_schema,
            "entries" => entries,
            "bytes" => bytes,
            "oldest_synchronized_at" => oldest,
            "newest_synchronized_at" => newest,
            "max_entries" => state.max_entries,
            "max_bytes" => state.max_bytes,
            "max_entry_bytes" => state.max_entry_bytes,
            "max_age_ms" => state.max_age_ms,
            "expires_at" => min(account.expires_at, state.expires_at)
          }}, state}

      _ ->
        {:reply, {:error, :cache_unavailable}, state}
    end
  end

  defp reply_clear(state, reply) do
    case safely(fn -> clear!(state.db) end) do
      {:ok, :ok} -> {:reply, reply, %{state | account: nil, expires_at: nil}}
      {:error, _} -> {:reply, {:error, :cache_unavailable}, state}
    end
  end

  defp clear!(db) do
    transaction!(db, fn ->
      execute!(db, "DELETE FROM projections")
      execute!(db, "UPDATE metadata SET account = NULL, expires_at = NULL WHERE singleton = 1")
    end)
  end

  defp delete_projection(state, account, kind, key, reply) do
    result =
      safely(fn ->
        run!(
          state.db,
          "DELETE FROM projections WHERE account = ? AND kind = ? AND cache_key = ?",
          [account, kind, key]
        )
      end)

    if match?({:ok, :ok}, result),
      do: {:reply, reply, state},
      else: {:reply, {:error, :cache_unavailable}, state}
  end

  defp touch!(db, account, kind, key, now) do
    run!(
      db,
      "UPDATE projections SET touched_at = ? WHERE account = ? AND kind = ? AND cache_key = ?",
      [now, account, kind, key]
    )
  end

  defp evict!(state) do
    case rows!(state.db, "SELECT COUNT(*), COALESCE(SUM(bytes), 0) FROM projections") do
      [[entries, bytes]] when entries > state.max_entries or bytes > state.max_bytes ->
        execute!(
          state.db,
          """
          DELETE FROM projections WHERE (account, kind, cache_key) IN (
            SELECT account, kind, cache_key FROM projections
            ORDER BY touched_at ASC, synchronized_at ASC, kind ASC, cache_key ASC LIMIT 1
          )
          """
        )

        evict!(state)

      [[_, _]] ->
        :ok

      _ ->
        throw({:cache, :cache_unavailable})
    end
  end

  defp expire_stale!(state, now) do
    threshold = max(now - state.max_age_ms, 0)
    run!(state.db, "DELETE FROM projections WHERE synchronized_at < ?", [threshold])
  end

  defp kind(value) when is_atom(value), do: kind(Atom.to_string(value))
  defp kind(value) when value in @kinds, do: {:ok, value}
  defp kind(_), do: {:error, :invalid_projection}

  defp key(value) do
    if text?(value, 512),
      do: :ok,
      else: {:error, :invalid_projection}
  end

  defp projection(value, maximum) when is_map(value) or is_list(value) do
    with true <- safe_projection?(value, 0),
         {:ok, bytes} <- Jason.encode(value),
         true <- byte_size(bytes) <= maximum do
      {:ok, bytes}
    else
      _ -> {:error, :invalid_projection}
    end
  rescue
    _ -> {:error, :invalid_projection}
  end

  defp projection(_, _), do: {:error, :invalid_projection}

  defp safe_projection?(_, depth) when depth > 32, do: false

  defp safe_projection?(value, depth) when is_map(value) do
    map_size(value) <= 1_024 and
      Enum.all?(value, fn
        {key, child} when is_binary(key) ->
          safe_field?(key) and safe_projection?(child, depth + 1)

        _ ->
          false
      end)
  end

  defp safe_projection?(value, depth) when is_list(value) do
    length(value) <= 4_096 and Enum.all?(value, &safe_projection?(&1, depth + 1))
  end

  defp safe_projection?(value, _depth)
       when is_nil(value) or is_boolean(value) or is_number(value),
       do: true

  defp safe_projection?(value, _depth) when is_binary(value),
    do: String.valid?(value) and not String.starts_with?(value, "Bearer ")

  defp safe_projection?(_, _), do: false

  defp safe_field?(field) do
    words =
      field
      |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1_\\2")
      |> String.downcase()
      |> String.split(~r/[^a-z0-9]+/, trim: true)

    not Enum.any?(words, &(&1 in @secret_words))
  end

  defp identifier?(value), do: text?(value, 256)

  defp text?(value, maximum),
    do: is_binary(value) and byte_size(value) in 1..maximum and String.valid?(value)

  defp timestamp(value) do
    if is_integer(value) and value in 0..@maximum_integer,
      do: :ok,
      else: {:error, :invalid_time}
  end

  defp execute!(db, sql), do: checked(Sqlite3.execute(db, sql))

  defp run!(db, sql, values) do
    statement = checked(Sqlite3.prepare(db, sql))

    try do
      checked(Sqlite3.bind(statement, values))
      checked(Sqlite3.step(db, statement))
      :ok
    after
      _ = Sqlite3.release(db, statement)
    end
  end

  defp rows!(db, sql, values \\ []) do
    statement = checked(Sqlite3.prepare(db, sql))

    try do
      checked(Sqlite3.bind(statement, values))
      checked(Sqlite3.fetch_all(db, statement))
    after
      _ = Sqlite3.release(db, statement)
    end
  end

  defp transaction!(db, fun) do
    execute!(db, "BEGIN IMMEDIATE")

    try do
      result = fun.()
      execute!(db, "COMMIT")
      result
    rescue
      error ->
        _ = Sqlite3.execute(db, "ROLLBACK")
        reraise(error, __STACKTRACE__)
    catch
      kind, reason ->
        _ = Sqlite3.execute(db, "ROLLBACK")
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp checked(:ok), do: :ok
  defp checked(:done), do: :done
  defp checked({:ok, value}), do: value
  defp checked({:error, _}), do: throw({:cache, :cache_unavailable})

  defp safely(fun) do
    {:ok, fun.()}
  rescue
    _ -> {:error, :cache_unavailable}
  catch
    {:cache, reason} -> {:error, reason}
    _, _ -> {:error, :cache_unavailable}
  end

  defp close(db, result) do
    _ = Sqlite3.close(db)
    result
  end
end
