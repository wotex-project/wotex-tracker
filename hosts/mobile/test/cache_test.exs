defmodule Wotex.Tracker.Mobile.CacheTest do
  @moduledoc false

  use ExUnit.Case, async: false
  import Bitwise

  alias Exqlite.Sqlite3
  alias Wotex.Tracker.Mobile.Cache

  @database "mobile-cache.sqlite3"

  test "stores closed offline projections with honest metadata" do
    {cache, _directory} = cache()
    account = account()

    assert :ok = Cache.bind(cache, account, 1_000)

    for {kind, projection, complete} <- [
          {:overview, %{"assets" => [%{"id" => "bike"}]}, true},
          {:history, [%{"at" => 900, "state" => "retained"}], false},
          {:dashboard, %{"series" => [1, 2, 3]}, true},
          {:map, %{"points" => [[59.3, 18.0]], "tiles" => "missing"}, false}
        ] do
      key = Atom.to_string(kind)
      assert :ok = Cache.put(cache, account, kind, key, projection, 900, complete, 1_000)

      assert {:ok,
              %{
                "schema" => "wtr.mobile-cache.v1",
                "source" => "offline_cache",
                "kind" => ^key,
                "key" => ^key,
                "projection" => ^projection,
                "synchronized_at" => 900,
                "age_ms" => 110,
                "complete" => ^complete,
                "expires_at" => 10_000
              }} = Cache.read(cache, account, kind, key, 1_010)
    end

    assert {:ok,
            %{
              "schema" => "wtr.mobile-cache.v1",
              "entries" => 4,
              "bytes" => bytes,
              "oldest_synchronized_at" => 900,
              "newest_synchronized_at" => 900,
              "max_entries" => 256,
              "max_bytes" => 16_777_216,
              "max_entry_bytes" => 1_048_576,
              "max_age_ms" => 604_800_000,
              "expires_at" => 10_000
            }} = Cache.status(cache, account, 1_010)

    assert bytes > 0
  end

  test "persists only the account fingerprint and requires the exact binding after restart" do
    directory = directory()
    first = account(%{"principal" => "private-principal", "installation_id" => "private-install"})
    cache = start_cache(directory)

    assert :ok = Cache.bind(cache, first, 100)

    assert :ok =
             Cache.put(cache, first, :overview, "home", %{"value" => "retained"}, 100, true, 100)

    stop_cache(cache)

    bytes = File.read!(Path.join(directory, @database))
    refute bytes =~ "private-principal"
    refute bytes =~ "private-install"

    cache = start_cache(directory)

    assert {:ok, %{"projection" => %{"value" => "retained"}}} =
             Cache.read(cache, first, :overview, "home", 101)

    changed_expiry = %{first | "expires_at" => 20_000}
    assert :ok = Cache.bind(cache, changed_expiry, 101)

    assert {:ok, %{"expires_at" => 20_000}} =
             Cache.read(cache, changed_expiry, :overview, "home", 102)

    mismatched = %{changed_expiry | "installation_id" => "another-install"}
    assert {:error, :account_mismatch} = Cache.read(cache, mismatched, :overview, "home", 102)
  end

  test "changing any authority fingerprint component securely purges the prior account" do
    {cache, directory} = cache()
    original = account()
    assert :ok = Cache.bind(cache, original, 100)

    changes = [
      %{"origin" => "https://other.example"},
      %{"principal" => "other-principal"},
      %{"scope" => "other-scope"},
      %{"credential_id" => "other-credential"},
      %{"installation_id" => "other-installation"}
    ]

    current =
      Enum.reduce(changes, original, fn change, current ->
        marker = "private-value-#{map_size(change)}-#{Map.values(change) |> hd()}"

        assert :ok =
                 Cache.put(
                   cache,
                   current,
                   :overview,
                   "home",
                   %{"value" => marker},
                   100,
                   true,
                   100
                 )

        next = Map.merge(current, change)
        assert :ok = Cache.bind(cache, next, 100)
        assert {:error, :cache_miss} = Cache.read(cache, next, :overview, "home", 100)
        assert {:error, :account_mismatch} = Cache.read(cache, current, :overview, "home", 100)
        next
      end)

    assert :ok =
             Cache.put(
               cache,
               current,
               :overview,
               "home",
               %{"value" => "last-private"},
               100,
               true,
               100
             )

    assert :ok = Cache.purge(cache)
    assert {:error, :account_mismatch} = Cache.status(cache, current, 100)
    stop_cache(cache)
    refute File.read!(Path.join(directory, @database)) =~ "last-private"
  end

  test "length-prefixes account fields so delimiter-bearing identities cannot collide" do
    {cache, _directory} = cache()
    first = account(%{"principal" => "a\0b", "scope" => "c"})
    second = account(%{"principal" => "a", "scope" => "b\0c"})

    assert :ok = Cache.bind(cache, first, 100)
    assert :ok = Cache.put(cache, first, :overview, "home", %{"value" => 1}, 100, true, 100)
    assert :ok = Cache.bind(cache, second, 100)
    assert {:error, :cache_miss} = Cache.read(cache, second, :overview, "home", 100)
    assert {:error, :account_mismatch} = Cache.read(cache, first, :overview, "home", 100)
  end

  test "expiration and explicit sign-out clear binding and retained projections" do
    directory = directory()
    account = account(%{"expires_at" => 200})
    cache = start_cache(directory)

    assert {:error, :expired} = Cache.bind(cache, account, 200)
    assert :ok = Cache.bind(cache, account, 100)
    assert :ok = Cache.put(cache, account, :history, "recent", [%{"at" => 100}], 100, false, 100)
    assert {:ok, %{"age_ms" => 99}} = Cache.read(cache, account, :history, "recent", 199)
    assert {:error, :expired} = Cache.read(cache, account, :history, "recent", 200)
    assert {:error, :account_mismatch} = Cache.status(cache, account, 199)

    renewed = %{account | "expires_at" => 300}
    assert :ok = Cache.bind(cache, renewed, 201)
    assert {:error, :cache_miss} = Cache.read(cache, renewed, :history, "recent", 201)
    assert :ok = Cache.purge(cache)
    stop_cache(cache)

    cache = start_cache(directory)
    assert {:error, :account_mismatch} = Cache.status(cache, renewed, 202)
  end

  test "evicts least-recently-used rows under entry and byte ceilings" do
    {cache, _directory} =
      cache(max_entries: 2, max_bytes: 1_024, max_entry_bytes: 800, max_age_ms: 10_000)

    account = account()
    assert :ok = Cache.bind(cache, account, 100)
    assert :ok = Cache.put(cache, account, :overview, "a", %{"value" => "a"}, 100, true, 100)
    assert :ok = Cache.put(cache, account, :overview, "b", %{"value" => "b"}, 101, true, 101)
    assert {:ok, _} = Cache.read(cache, account, :overview, "a", 102)
    assert :ok = Cache.put(cache, account, :overview, "c", %{"value" => "c"}, 103, true, 103)
    assert {:ok, _} = Cache.read(cache, account, :overview, "a", 104)
    assert {:error, :cache_miss} = Cache.read(cache, account, :overview, "b", 104)
    assert {:ok, _} = Cache.read(cache, account, :overview, "c", 104)

    large = %{"value" => String.duplicate("x", 690)}
    assert :ok = Cache.put(cache, account, :dashboard, "large-1", large, 105, true, 105)
    assert :ok = Cache.put(cache, account, :dashboard, "large-2", large, 106, true, 106)
    assert {:error, :cache_miss} = Cache.read(cache, account, :dashboard, "large-1", 106)
    assert {:ok, _} = Cache.read(cache, account, :dashboard, "large-2", 106)
    assert {:ok, %{"entries" => entries, "bytes" => bytes}} = Cache.status(cache, account, 106)
    assert entries <= 2
    assert bytes <= 1_024
  end

  test "expires stale entries while preserving the exact retention boundary" do
    {cache, _directory} = cache(max_age_ms: 100)
    account = account()
    assert :ok = Cache.bind(cache, account, 100)
    assert :ok = Cache.put(cache, account, :map, "route", %{"points" => []}, 100, false, 100)
    assert {:ok, %{"age_ms" => 100}} = Cache.read(cache, account, :map, "route", 200)
    assert {:error, :cache_miss} = Cache.read(cache, account, :map, "route", 201)

    assert :ok = Cache.put(cache, account, :map, "old", %{"points" => []}, 200, false, 200)
    assert {:ok, %{"entries" => 0, "bytes" => 0}} = Cache.status(cache, account, 301)
  end

  test "rejects malformed, oversized and credential-bearing projections without crashing" do
    {cache, directory} = cache(max_entry_bytes: 256)
    account = account()
    assert :ok = Cache.bind(cache, account, 100)

    for projection <- [
          :not_json,
          %{atom_key: "value"},
          %{"token" => "secret-token"},
          %{"apiToken" => "secret-token"},
          %{"csrf-token" => "secret-token"},
          %{"nested" => %{"proof" => "secret-proof"}},
          %{"value" => "Bearer secret-bearer"},
          %{<<255>> => "invalid-utf8-key"},
          %{"value" => self()},
          %{"value" => String.duplicate("x", 300)},
          Enum.to_list(1..4_097),
          deep_projection(34)
        ] do
      assert {:error, :invalid_projection} =
               Cache.put(cache, account, :overview, "unsafe", projection, 100, true, 100)
    end

    for {kind, key} <- [
          {:unknown, "key"},
          {:overview, ""},
          {:overview, String.duplicate("x", 513)}
        ] do
      assert {:error, :invalid_projection} =
               Cache.put(cache, account, kind, key, %{"value" => 1}, 100, true, 100)
    end

    assert {:error, :invalid_projection} =
             Cache.put(cache, account, :overview, "future", %{"value" => 1}, 101, true, 100)

    assert {:error, :invalid_time} =
             Cache.put(cache, account, :overview, "negative", %{"value" => 1}, -1, true, 100)

    assert {:error, :invalid_time} = Cache.status(cache, account, -1)
    assert {:ok, %{"entries" => 0}} = Cache.status(cache, account, 100)
    stop_cache(cache)

    bytes = File.read!(Path.join(directory, @database))
    refute bytes =~ "secret-token"
    refute bytes =~ "secret-proof"
    refute bytes =~ "secret-bearer"
  end

  test "rejects malformed accounts and origins without changing the active binding" do
    {cache, _directory} = cache()
    valid = account()
    assert :ok = Cache.bind(cache, valid, 100)

    invalid = [
      Map.delete(valid, "scope"),
      Map.put(valid, "extra", true),
      %{valid | "schema" => "wtr.mobile-account.v2"},
      %{valid | "origin" => "http://service.example"},
      %{valid | "origin" => "https://SERVICE.example"},
      %{valid | "origin" => "https://service.example/"},
      %{valid | "origin" => "https://user@service.example"},
      %{valid | "origin" => "https://service.example?q=1"},
      %{valid | "origin" => "https://service.example#fragment"},
      %{valid | "origin" => "https://service.example:0"},
      %{valid | "origin" => 1},
      %{valid | "principal" => ""},
      %{valid | "scope" => String.duplicate("x", 257)},
      %{valid | "expires_at" => -1}
    ]

    for input <- invalid do
      assert {:error, :invalid_account} = Cache.bind(cache, input, 100)
    end

    assert {:ok, %{"entries" => 0}} = Cache.status(cache, valid, 100)
  end

  test "serializes concurrent writers and retains the configured bound" do
    {cache, _directory} = cache(max_entries: 10, max_bytes: 8_192, max_entry_bytes: 512)
    account = account()
    assert :ok = Cache.bind(cache, account, 100)

    1..40
    |> Task.async_stream(
      fn number ->
        Cache.put(
          cache,
          account,
          :history,
          Integer.to_string(number),
          %{"number" => number},
          100 + number,
          rem(number, 2) == 0,
          100 + number
        )
      end,
      max_concurrency: 16,
      timeout: 5_000
    )
    |> Enum.each(fn result -> assert {:ok, :ok} = result end)

    assert {:ok, %{"entries" => 10, "bytes" => bytes}} = Cache.status(cache, account, 141)
    assert bytes <= 8_192
  end

  test "contains database failures behind bounded cache errors" do
    {cache, _directory} = cache()
    account = account()
    assert :ok = Cache.bind(cache, account, 100)
    assert :ok = Sqlite3.close(:sys.get_state(cache).db)

    assert {:error, :cache_unavailable} = Cache.bind(cache, account, 100)

    assert {:error, :cache_unavailable} =
             Cache.put(cache, account, :overview, "home", %{"value" => 1}, 100, true, 100)

    assert {:error, :cache_unavailable} = Cache.read(cache, account, :overview, "home", 100)
    assert {:error, :cache_unavailable} = Cache.status(cache, account, 100)
    assert {:error, :cache_unavailable} = Cache.purge(cache)
  end

  test "starts the mobile host without starting another host application" do
    assert {:ok, supervisor} = Wotex.Tracker.Mobile.Application.start(:normal, [])

    assert [{_, host_supervisor, :supervisor, [DynamicSupervisor]}] =
             Supervisor.which_children(supervisor)

    assert [] = DynamicSupervisor.which_children(host_supervisor)
    assert :ok = Supervisor.stop(supervisor)
  end

  test "validates configuration and private storage paths" do
    private = directory()

    for options <- [
          [],
          [directory: private, extra: true],
          [directory: private, max_entries: 0],
          [directory: private, max_bytes: 1_023],
          [directory: private, max_entry_bytes: 255],
          [directory: private, max_entry_bytes: 2_048, max_bytes: 1_024],
          [directory: private, max_age_ms: 99],
          [directory: private, name: :one, name: :two]
        ] do
      assert {:error, :invalid_configuration} = failed_start(options)
    end

    assert {:error, :unsafe_path} = failed_start(directory: "relative")
    assert {:error, :unsafe_path} = failed_start(directory: "/" <> String.duplicate("x", 4_097))
    assert {:error, :unsafe_path} = failed_start(directory: Path.join(private, "missing"))

    public = directory()
    File.chmod!(public, 0o755)
    assert {:error, :unsafe_path} = failed_start(directory: public)

    readonly = directory()
    File.chmod!(readonly, 0o500)
    assert {:error, :cache_unavailable} = failed_start(directory: readonly)
    File.chmod!(readonly, 0o700)

    target = directory()
    linked = Path.join(directory(), "linked")
    File.ln_s!(target, linked)
    assert {:error, :unsafe_path} = failed_start(directory: linked)

    directory_db = directory()
    File.mkdir!(Path.join(directory_db, @database))
    assert {:error, :unsafe_path} = failed_start(directory: directory_db)

    insecure_db = directory()
    File.write!(Path.join(insecure_db, @database), "")
    assert {:error, :unsafe_path} = failed_start(directory: insecure_db)

    hardlinked_db = directory()
    path = Path.join(hardlinked_db, @database)
    File.write!(path, "")
    File.chmod!(path, 0o600)
    File.ln!(path, Path.join(hardlinked_db, "duplicate"))
    assert {:error, :unsafe_path} = failed_start(directory: hardlinked_db)

    created = directory()
    cache = start_cache(created)
    stop_cache(cache)
    assert {:ok, stat} = File.stat(Path.join(created, @database))
    assert (stat.mode &&& 0o077) == 0
  end

  test "fails closed on future, malformed and corrupt cache schemas" do
    directory = directory()
    account = account()
    cache = start_cache(directory)
    assert :ok = Cache.bind(cache, account, 100)

    assert :ok =
             Cache.put(
               cache,
               account,
               :overview,
               "home",
               %{"value" => "still-here"},
               100,
               true,
               100
             )

    stop_cache(cache)

    path = Path.join(directory, @database)
    with_db(path, fn db -> :ok = Sqlite3.execute(db, "PRAGMA user_version = 2") end)
    assert {:error, :unsupported_cache} = failed_start(directory: directory)

    with_db(path, fn db -> :ok = Sqlite3.execute(db, "PRAGMA user_version = 1") end)
    cache = start_cache(directory)

    assert {:ok, %{"projection" => %{"value" => "still-here"}}} =
             Cache.read(cache, account, :overview, "home", 101)

    stop_cache(cache)

    malformed = directory()
    malformed_path = Path.join(malformed, @database)
    File.write!(malformed_path, "")
    File.chmod!(malformed_path, 0o600)

    with_db(malformed_path, fn db ->
      :ok = Sqlite3.execute(db, "CREATE TABLE metadata(singleton INTEGER, schema TEXT)")
      :ok = Sqlite3.execute(db, "INSERT INTO metadata VALUES (1, 'wtr.mobile-cache.v1')")
      :ok = Sqlite3.execute(db, "PRAGMA user_version = 1")
    end)

    assert {:error, :unsupported_cache} = failed_start(directory: malformed)

    invalid_binding = directory()
    cache = start_cache(invalid_binding)
    stop_cache(cache)

    with_db(Path.join(invalid_binding, @database), fn db ->
      :ok = Sqlite3.execute(db, "UPDATE metadata SET account = NULL, expires_at = 1")
    end)

    assert {:error, :cache_unavailable} = failed_start(directory: invalid_binding)

    corrupt = directory()
    corrupt_path = Path.join(corrupt, @database)
    File.write!(corrupt_path, "not a sqlite database")
    File.chmod!(corrupt_path, 0o600)
    assert {:error, :cache_unavailable} = failed_start(directory: corrupt)
  end

  test "removes malformed retained JSON instead of presenting it" do
    directory = directory()
    account = account()
    cache = start_cache(directory)
    assert :ok = Cache.bind(cache, account, 100)
    assert :ok = Cache.put(cache, account, :overview, "home", %{"value" => 1}, 100, true, 100)
    stop_cache(cache)

    with_db(Path.join(directory, @database), fn db ->
      execute(db, "UPDATE projections SET payload = ?", [{:blob, "{"}])
    end)

    cache = start_cache(directory)
    assert {:error, :cache_unavailable} = Cache.read(cache, account, :overview, "home", 101)
    assert {:error, :cache_miss} = Cache.read(cache, account, :overview, "home", 101)
  end

  test "exposes no offline mutation or physical Action queue" do
    refute function_exported?(Cache, :enqueue, 2)
    refute function_exported?(Cache, :mutate, 3)
    refute function_exported?(Cache, :invoke_action, 3)
    refute function_exported?(Cache, :pending, 1)
  end

  defp cache(options \\ []) do
    directory = directory()
    {start_cache(directory, options), directory}
  end

  defp start_cache(directory, options \\ []) do
    {:ok, cache} = Cache.start_link([directory: directory] ++ options)
    cache
  end

  defp stop_cache(cache) do
    if Process.alive?(cache), do: GenServer.stop(cache)
  end

  defp directory do
    path = Path.expand("_build/test/cache-fixtures/#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    File.chmod!(path, 0o700)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp failed_start(options) do
    Task.async(fn ->
      Process.flag(:trap_exit, true)
      Cache.start_link(options)
    end)
    |> Task.await()
  end

  defp account(overrides \\ %{}) do
    Map.merge(
      %{
        "schema" => "wtr.mobile-account.v1",
        "origin" => "https://service.example",
        "principal" => "owner",
        "scope" => "bikes",
        "credential_id" => "phone",
        "installation_id" => "installation",
        "expires_at" => 10_000
      },
      overrides
    )
  end

  defp deep_projection(depth) do
    Enum.reduce(1..depth, %{"value" => true}, fn number, child ->
      %{"level-#{number}" => child}
    end)
  end

  defp with_db(path, fun) do
    {:ok, db} = Sqlite3.open(path)

    try do
      fun.(db)
    after
      :ok = Sqlite3.close(db)
    end
  end

  defp execute(db, sql, values) do
    {:ok, statement} = Sqlite3.prepare(db, sql)

    try do
      :ok = Sqlite3.bind(statement, values)
      :done = Sqlite3.step(db, statement)
    after
      :ok = Sqlite3.release(db, statement)
    end
  end
end
