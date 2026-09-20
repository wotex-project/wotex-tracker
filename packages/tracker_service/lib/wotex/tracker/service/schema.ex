defmodule Wotex.Tracker.Service.Schema do
  @moduledoc false

  alias Wotex.Tracker.Service.SQL

  # Every supported older version upgrades to schema 8 in one startup transaction.
  @migrations %{
    1 => ~w(1-to-2.sql 2-to-3.sql 3-to-4.sql 4-to-5.sql 5-to-6.sql 6-to-7.sql 7-to-8.sql),
    2 => ~w(2-to-3.sql 3-to-4.sql 4-to-5.sql 5-to-6.sql 6-to-7.sql 7-to-8.sql),
    3 => ~w(3-to-4.sql 4-to-5.sql 5-to-6.sql 6-to-7.sql 7-to-8.sql),
    4 => ~w(4-to-5.sql 5-to-6.sql 6-to-7.sql 7-to-8.sql),
    5 => ~w(5-to-6.sql 6-to-7.sql 7-to-8.sql),
    6 => ~w(6-to-7.sql 7-to-8.sql),
    7 => ~w(7-to-8.sql),
    8 => []
  }

  def initialize(db, options) do
    SQL.execute!(db, "PRAGMA busy_timeout=#{options.busy_timeout}")
    SQL.execute!(db, "PRAGMA foreign_keys=ON; PRAGMA synchronous=FULL; PRAGMA secure_delete=ON")
    require_value!(SQL.rows!(db, "PRAGMA secure_delete"), [[1]])
    require_value!(SQL.rows!(db, "PRAGMA page_size"), [[4096]])
    require_value!(SQL.rows!(db, "PRAGMA journal_mode=WAL"), [["wal"]])
    SQL.rows!(db, "PRAGMA max_page_count=#{options.max_pages}")
    SQL.rows!(db, "PRAGMA wal_autocheckpoint=1000")
    SQL.execute!(db, "BEGIN IMMEDIATE")

    try do
      case SQL.rows!(db, "PRAGMA user_version") do
        [[0]] ->
          create(db)

        [[version]] when is_map_key(@migrations, version) ->
          require_value!(SQL.rows!(db, "PRAGMA application_id"), [[1_465_143_857]])
          Enum.each(@migrations[version], &migrate(db, &1))

        _ ->
          throw({:storage, :unsupported_schema})
      end

      SQL.execute!(db, "COMMIT")
      validate_tables(db)

      case SQL.rows!(db, "PRAGMA quick_check") do
        [["ok"]] -> :ok
        _ -> throw({:storage, :storage_corrupt})
      end
    after
      SQL.rollback(db)
    end
  end

  defp create(db) do
    require_value!(SQL.rows!(db, "SELECT name FROM sqlite_master WHERE type='table'"), [])

    :wotex_tracker_service
    |> :code.priv_dir()
    |> Path.join("schema/8.sql")
    |> File.read!()
    |> then(&SQL.execute!(db, &1))
  end

  defp migrate(db, file) do
    :wotex_tracker_service
    |> :code.priv_dir()
    |> Path.join("schema/#{file}")
    |> File.read!()
    |> then(&SQL.execute!(db, &1))
  end

  defp validate_tables(db) do
    for {table, columns} <- [
          {"scopes", "scope,generation"},
          {"operations", "scope,principal,id,digest,result,expires_at"},
          {"observations", "scope,id,digest,generation,document"},
          {"records", "scope,kind,id,generation,document"},
          {"events", "sequence,scope,generation,created_at,document"},
          {"publications", "scope,thing_id,generation,operation_id,document,status,cleanup"},
          {"forward_queue",
           "scope,id,digest,document,size_bytes,admitted_at,expires_at,attempts,next_attempt_at,max_attempts,status,outcome,settled_at"},
          {"rule_states",
           "scope,kind,rule_id,state_identity,document,generation,evaluated_at,transition_identity"},
          {"rule_event_intents",
           "scope,id,digest,kind,rule_id,generation,created_at,document,mode,action"},
          {"access_audit",
           "sequence,scope,credential_id,principal,permission,activity,occurred_at"},
          {"access_audit_state", "scope,coverage_started_at,truncated"}
        ] do
      SQL.rows!(db, "SELECT #{columns} FROM #{table} LIMIT 0")
    end

    :ok
  end

  defp require_value!(value, value), do: :ok
  defp require_value!(_, _), do: throw({:storage, :unsupported_schema})
end
