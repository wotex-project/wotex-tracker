defmodule Wotex.Tracker.Service.StorePathTest do
  @moduledoc false

  use ExUnit.Case, async: true
  import Wotex.Tracker.Service.Fixtures
  alias Exqlite.Sqlite3
  alias Wotex.Tracker.Service.{Store, StorePath}

  test "unsafe paths, directory modes, symlinks, hardlinks and unsafe sidecars fail closed" do
    assert {:error, :unsafe_path} = StorePath.database(nil)
    assert {:error, :unsafe_path} = StorePath.database("relative")
    assert {:error, :unsafe_path} = StorePath.backup_target(nil)
    path = directory()
    File.chmod!(path, 0o755)
    assert {:error, :unsafe_path} = StorePath.database(path)
    File.chmod!(path, 0o700)
    linked = Path.join(directory(), "linked")
    File.ln_s!(path, linked)
    assert {:error, :unsafe_path} = StorePath.database(linked)
    db_path = Path.join(path, "tracker.db")
    File.mkdir!(db_path)
    assert {:error, :unsafe_path} = StorePath.database(path)
    File.rmdir!(db_path)
    File.write!(db_path, "")
    assert {:error, :unsafe_path} = StorePath.database(path)
    File.chmod!(db_path, 0o600)
    link = Path.join(path, "duplicate")
    File.ln!(db_path, link)
    assert {:error, :unsafe_path} = StorePath.database(path)
    File.rm!(link)
    File.ln_s!(db_path, db_path <> "-wal")
    assert {:error, :unsafe_path} = StorePath.database(path)
    File.rm!(db_path <> "-wal")
    assert {:ok, ^db_path} = StorePath.database(path)
  end

  test "invalid options and unknown schema versions fail startup without destroying stored data" do
    for options <- [
          [],
          [directory: directory(), max_rows: 0],
          [directory: directory(), max_pages: 262_145],
          [directory: directory(), forward_max_items: 0],
          [directory: directory(), forward_max_bytes: 16_777_217],
          [directory: directory(), forward_max_age_ms: 604_800_001],
          [directory: directory(), forward_max_attempts: 9],
          [directory: directory(), domain_inactivity_retention_ms: 0],
          [directory: directory(), domain_inactivity_retention_ms: 31_536_000_001],
          [directory: directory(), retention_check_ms: 86_400_001],
          [directory: directory(), extra: 1],
          [directory: directory(), timeout: 1, timeout: 2],
          [directory: directory(), fault: :not_function]
        ] do
      assert {:error, {:invalid_options, _}} = start_supervised({Store, options})
    end

    path = directory()
    {:ok, db_path} = StorePath.database(path)
    {:ok, db} = Sqlite3.open(db_path)
    :ok = Sqlite3.execute(db, "PRAGMA user_version=4")
    Sqlite3.close(db)
    assert {:error, {:unsupported_schema, _}} = start_supervised({Store, directory: path})
    {:ok, db} = Sqlite3.open(db_path)
    :ok = Sqlite3.execute(db, "PRAGMA user_version=0; CREATE TABLE unrelated(value TEXT)")
    Sqlite3.close(db)
    assert {:error, {:unsupported_schema, _}} = start_supervised({Store, directory: path})
    {:ok, db} = Sqlite3.open(db_path)
    :ok = Sqlite3.execute(db, "DROP TABLE unrelated; PRAGMA user_version=1")
    Sqlite3.close(db)
    assert {:error, {:unsupported_schema, _}} = start_supervised({Store, directory: path})
  end

  test "corrupt databases and nonexistent directories return bounded startup errors" do
    path = directory()
    assert {:error, {:unsafe_path, _}} = start_supervised({Store, directory: path <> "/missing"})
    {:ok, db_path} = StorePath.database(path)
    File.write!(db_path, "private corruption text")
    assert {:error, {:storage_unavailable, _}} = start_supervised({Store, directory: path})
  end
end
