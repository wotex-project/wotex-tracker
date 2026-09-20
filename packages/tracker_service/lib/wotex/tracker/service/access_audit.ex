defmodule Wotex.Tracker.Service.AccessAudit do
  @moduledoc false

  alias Wotex.Tracker.Service.{Access, Codec, SQL}

  @retention_ms 2_592_000_000
  @maximum_entries 10_000
  @permissions ~w(admin enroll ingest interact raw read)

  def retention_ms, do: @retention_ms
  def maximum_entries, do: @maximum_entries

  def record(db, %Access{} = access, permission, activity, now, authorize) do
    with true <- audit_value?(access.scope) and audit_value?(access.credential_id),
         true <- audit_value?(access.principal) and permission in @permissions,
         true <- audit_value?(activity) and Codec.time?(now) do
      SQL.execute!(db, "BEGIN IMMEDIATE")

      try do
        authorize.()
        initialize(db, access.scope, now)
        expire(db, access.scope, now)
        bound(db, access.scope)

        SQL.rows!(db, "INSERT INTO access_audit VALUES(NULL,?,?,?,?,?,?)", [
          access.scope,
          access.credential_id,
          access.principal,
          permission,
          activity,
          now
        ])

        SQL.execute!(db, "COMMIT")
        :ok
      after
        SQL.rollback(db)
      end
    else
      _ -> {:error, :invalid_query}
    end
  end

  def record(_, _, _, _, _, authorize) do
    authorize.()
    {:error, :invalid_query}
  end

  def page(db, %Access{} = access, query, authorize) do
    with {:ok, admitted} <- query(query),
         true <- access.scope == admitted.scope do
      SQL.execute!(db, "BEGIN")

      try do
        authorize.()
        snapshot = admitted.snapshot || maximum_sequence(db, admitted.scope)
        if snapshot > maximum_sequence(db, admitted.scope), do: throw({:storage, :invalid_cursor})

        before = admitted.before || snapshot + 1

        rows =
          SQL.rows!(
            db,
            """
            SELECT sequence,credential_id,principal,permission,activity,occurred_at
            FROM access_audit WHERE scope=? AND sequence<=? AND sequence<?
            ORDER BY sequence DESC LIMIT ?
            """,
            [admitted.scope, snapshot, before, admitted.limit + 1]
          )

        {items, next} = page_rows(rows, admitted.limit)
        [coverage_started_at, truncated] = state(db, admitted.scope)

        {:ok,
         %{
           "snapshot" => Integer.to_string(snapshot),
           "items" => Enum.map(items, &item/1),
           "next" => next,
           "coverage_started_at" => coverage_started_at,
           "retention_ms" => @retention_ms,
           "maximum_entries" => @maximum_entries,
           "truncated" => truncated == 1
         }}
      after
        SQL.rollback(db)
      end
    else
      _ -> {:error, :invalid_query}
    end
  end

  def page(_, _, _, _), do: {:error, :invalid_query}

  defp query(%{scope: scope, snapshot: snapshot, before: before, limit: limit} = query)
       when map_size(query) == 4 do
    with true <- audit_value?(scope) and is_integer(limit) and limit in 1..100,
         {:ok, snapshot} <- optional_generation(snapshot),
         {:ok, before} <- optional_generation(before) do
      {:ok, %{scope: scope, snapshot: snapshot, before: before, limit: limit}}
    else
      _ -> {:error, :invalid_query}
    end
  end

  defp query(_), do: {:error, :invalid_query}

  defp optional_generation(nil), do: {:ok, nil}
  defp optional_generation(value), do: Codec.generation(value)

  defp initialize(db, scope, now) do
    SQL.rows!(db, "INSERT OR IGNORE INTO access_audit_state VALUES(?,?,0)", [scope, now])
  end

  defp expire(db, scope, now) do
    cutoff = max(0, now - @retention_ms)
    SQL.rows!(db, "DELETE FROM access_audit WHERE scope=? AND occurred_at<=?", [scope, cutoff])
    mark_truncated_if_changed(db, scope)
  end

  defp bound(db, scope) do
    [[count]] = SQL.rows!(db, "SELECT count(*) FROM access_audit WHERE scope=?", [scope])
    overflow = count - @maximum_entries + 1

    if overflow > 0 do
      SQL.rows!(
        db,
        "DELETE FROM access_audit WHERE sequence IN (SELECT sequence FROM access_audit WHERE scope=? ORDER BY sequence LIMIT ?)",
        [scope, overflow]
      )

      SQL.rows!(db, "UPDATE access_audit_state SET truncated=1 WHERE scope=?", [scope])
    end
  end

  defp mark_truncated_if_changed(db, scope) do
    case SQL.rows!(db, "SELECT changes()") do
      [[count]] when count > 0 ->
        SQL.rows!(db, "UPDATE access_audit_state SET truncated=1 WHERE scope=?", [scope])

      _ ->
        :ok
    end
  end

  defp maximum_sequence(db, scope) do
    [[sequence]] =
      SQL.rows!(db, "SELECT coalesce(max(sequence),0) FROM access_audit WHERE scope=?", [scope])

    sequence
  end

  defp state(db, scope) do
    case SQL.rows!(
           db,
           "SELECT coverage_started_at,truncated FROM access_audit_state WHERE scope=?",
           [scope]
         ) do
      [state] -> state
      [] -> [0, 0]
    end
  end

  defp page_rows(rows, limit) do
    if length(rows) > limit do
      items = Enum.take(rows, limit)
      {items, items |> List.last() |> hd() |> Integer.to_string()}
    else
      {rows, nil}
    end
  end

  defp item([_sequence, credential, principal, permission, activity, occurred_at]),
    do: %{
      "schema" => "wtr.access-audit-entry.v1",
      "credential_id" => credential,
      "principal" => principal,
      "permission" => permission,
      "activity" => activity,
      "occurred_at" => occurred_at
    }

  defp audit_value?(value), do: Codec.id?(value)
end
