defmodule Wotex.Tracker.Service.Read do
  @moduledoc false

  alias Wotex.Tracker.Service.{Codec, SQL, Transaction, Update}

  @retention 604_800_000

  def fetch(db, query, authorize \\ fn -> :ok end) do
    with %{scope: scope, kind: kind, id: id, generation: generation} when map_size(query) == 4 <-
           query,
         true <-
           Codec.id?(scope) and Codec.id?(id) and (kind == "observations" or record_kind?(kind)),
         {:ok, version} <- requested_generation(db, %{generation: generation}) do
      SQL.execute!(db, "BEGIN")

      try do
        authorize.()
        current = Transaction.generation(db, scope)
        version = version || current
        if version > current, do: throw({:storage, :invalid_cursor})

        with {:ok, row} <- fetch_row(db, scope, kind, id, version) do
          [[cursor]] =
            SQL.rows!(
              db,
              "SELECT coalesce(max(sequence),0) FROM events WHERE scope=? AND generation<=?",
              [scope, version]
            )

          {:ok, Map.put(row, "event_cursor", Integer.to_string(cursor))}
        end
      after
        SQL.rollback(db)
      end
    else
      _ -> {:error, :invalid_query}
    end
  end

  def snapshot(db, query, authorize \\ fn -> :ok end) do
    with true <- valid_query?(query),
         {:ok, generation} <- requested_generation(db, query) do
      SQL.execute!(db, "BEGIN")

      try do
        authorize.()
        # The caller's first generation and high-water cursor share one snapshot.
        current = Transaction.generation(db, query.scope)
        generation = generation || current
        if generation > current, do: throw({:storage, :invalid_cursor})
        rows = page(db, query, generation)

        items =
          Enum.map(rows, fn [id, document, version] ->
            %{
              "id" => id,
              "generation" => Integer.to_string(version),
              "value" => Codec.decode!(document)
            }
          end)

        [[cursor]] =
          SQL.rows!(
            db,
            "SELECT coalesce(max(sequence),0) FROM events WHERE scope=? AND generation<=?",
            [query.scope, generation]
          )

        next = if length(items) == query.limit, do: List.last(items)["id"], else: nil

        result = %{
          "generation" => Integer.to_string(generation),
          "event_cursor" => Integer.to_string(cursor),
          "items" => items,
          "next" => next
        }

        bounded(result)
      after
        SQL.rollback(db)
      end
    else
      _ -> {:error, :invalid_query}
    end
  end

  # Each Thing admits at most eight definitions; the extra row detects a violated bound.
  def policies(db, scope, thing, generation, authorize) do
    with true <- Codec.id?(scope) and Codec.id?(thing),
         {:ok, requested} <- requested_generation(db, %{generation: generation}) do
      SQL.execute!(db, "BEGIN")

      try do
        authorize.()
        current = Transaction.generation(db, scope)
        version = requested || current
        if version > current, do: throw({:storage, :invalid_cursor})

        rows =
          SQL.rows!(
            db,
            """
            SELECT r.id,r.document FROM records r
            WHERE r.scope=? AND r.kind='policies' AND r.generation<=?
            AND r.generation=(SELECT max(v.generation) FROM records v WHERE v.scope=r.scope AND v.kind=r.kind AND v.id=r.id AND v.generation<=?)
            AND r.document!='null' AND json_extract(r.document,'$.public.thing_id')=?
            ORDER BY r.id LIMIT 9
            """,
            [scope, version, version, thing]
          )

        if length(rows) > 8, do: throw({:storage, :storage_unavailable})

        {:ok,
         %{
           "generation" => Integer.to_string(version),
           "items" =>
             Enum.map(rows, fn [id, document] ->
               %{"id" => id, "value" => Codec.decode!(document)}
             end)
         }}
      after
        SQL.rollback(db)
      end
    else
      _ -> {:error, :invalid_query}
    end
  end

  # Revocation is permanent, so each named credential has at most one access record.
  def revocations(db, scope, ids, authorize) do
    with true <- Codec.id?(scope) and is_list(ids) and length(ids) <= 32,
         true <- Enum.all?(ids, &Codec.id?/1) do
      SQL.execute!(db, "BEGIN")

      try do
        authorize.()
        current = Transaction.generation(db, scope)

        rows =
          if ids == [],
            do: [],
            else:
              SQL.rows!(
                db,
                """
                SELECT id,generation,document FROM records
                WHERE scope=? AND kind='access' AND generation<=? AND id IN (#{Enum.map_join(ids, ",", fn _ -> "?" end)})
                ORDER BY id,generation
                """,
                [scope, current | ids]
              )

        {:ok,
         %{
           "generation" => Integer.to_string(current),
           "items" =>
             rows
             |> Enum.uniq_by(fn [id | _] -> id end)
             |> Enum.map(fn [id, generation, document] ->
               %{
                 "id" => id,
                 "generation" => Integer.to_string(generation),
                 "value" => Codec.decode!(document)
               }
             end)
         }}
      after
        SQL.rollback(db)
      end
    else
      _ -> {:error, :invalid_query}
    end
  end

  def events(db, query, authorize \\ fn -> :ok end)

  def events(db, %{scope: scope, after: cursor, limit: limit, now: now} = query, authorize)
      when map_size(query) in 4..5 do
    with true <- Codec.id?(scope) and Codec.time?(now) and is_integer(limit) and limit in 1..100,
         true <-
           Enum.all?(
             Map.keys(query),
             &(&1 in [:scope, :after, :limit, :now, :snapshot_generation])
           ),
         {:ok, snapshot} <- snapshot_generation(query),
         {:ok, sequence} <- Codec.generation(cursor) do
      SQL.execute!(db, "BEGIN")

      try do
        authorize.()
        validate_cursor!(db, scope, sequence, now, snapshot)

        rows =
          SQL.rows!(
            db,
            "SELECT sequence,generation,document,created_at FROM events WHERE scope=? AND sequence>? ORDER BY sequence LIMIT ?",
            [scope, sequence, limit]
          )

        if Enum.any?(rows, fn [_, _, _, time] -> time + @retention <= now end),
          do: throw({:storage, :cursor_expired})

        items =
          Enum.map(rows, fn [id, generation, document, _] ->
            %{
              "schema" => "wtr.event.v1",
              "id" => Integer.to_string(id),
              "generation" => Integer.to_string(generation),
              "event" => Codec.decode!(document)
            }
          end)

        next = if items == [], do: cursor, else: List.last(items)["id"]
        bounded(%{"items" => items, "next" => next})
      after
        SQL.rollback(db)
      end
    else
      _ -> {:error, :invalid_query}
    end
  end

  def events(_, _, _), do: {:error, :invalid_query}

  def history(db, query, authorize \\ fn -> :ok end) do
    with true <- history_query?(query),
         {:ok, generation} <- requested_generation(db, query),
         {:ok, after_generation} <- Codec.generation(query.after) do
      SQL.execute!(db, "BEGIN")

      try do
        authorize.()
        current = Transaction.generation(db, query.scope)
        generation = generation || current

        if generation > current or after_generation > generation,
          do: throw({:storage, :invalid_cursor})

        rows =
          SQL.rows!(
            db,
            """
            SELECT document,generation FROM records
            WHERE scope=? AND kind=? AND id=? AND generation>? AND generation<=?
            ORDER BY generation LIMIT ?
            """,
            [query.scope, query.kind, query.id, after_generation, generation, query.limit + 1]
          )

        if rows == [] and after_generation == 0 do
          {:error, :not_found}
        else
          history_page(db, query, rows, generation)
        end
      after
        SQL.rollback(db)
      end
    else
      _ -> {:error, :invalid_query}
    end
  end

  defp history_query?(
         %{
           scope: scope,
           kind: kind,
           id: id,
           generation: generation,
           after: position,
           limit: limit
         } = query
       )
       when map_size(query) == 6 do
    Codec.id?(scope) and Codec.id?(id) and record_kind?(kind) and
      (is_nil(generation) or is_binary(generation)) and is_binary(position) and
      is_integer(limit) and limit in 1..100
  end

  defp history_query?(_), do: false

  defp history_page(db, query, rows, generation) do
    items =
      rows
      |> Enum.take(query.limit)
      |> Enum.map(fn [document, version] ->
        %{
          "id" => query.id,
          "generation" => Integer.to_string(version),
          "deleted" => document == "null",
          "value" => Codec.decode!(document)
        }
      end)

    [[cursor]] =
      SQL.rows!(
        db,
        "SELECT coalesce(max(sequence),0) FROM events WHERE scope=? AND generation<=?",
        [query.scope, generation]
      )

    next = if length(rows) > query.limit, do: List.last(items)["generation"], else: nil

    bounded(%{
      "items" => items,
      "generation" => Integer.to_string(generation),
      "event_cursor" => Integer.to_string(cursor),
      "next" => next
    })
  end

  defp snapshot_generation(%{snapshot_generation: value}), do: Codec.generation(value)
  defp snapshot_generation(_), do: {:ok, nil}

  defp validate_cursor!(db, scope, sequence, _now, snapshot) when is_integer(snapshot) do
    current = Transaction.generation(db, scope)

    [[cursor]] =
      SQL.rows!(
        db,
        "SELECT coalesce(max(sequence),0) FROM events WHERE scope=? AND generation<=?",
        [scope, snapshot]
      )

    if snapshot > current or cursor != sequence, do: throw({:storage, :invalid_cursor})
    :ok
  end

  defp validate_cursor!(_db, _scope, 0, _now, nil), do: :ok

  defp validate_cursor!(db, scope, sequence, now, nil) do
    case SQL.rows!(db, "SELECT created_at FROM events WHERE scope=? AND sequence=?", [
           scope,
           sequence
         ]) do
      [[time]] when time + @retention > now -> :ok
      [[_]] -> throw({:storage, :cursor_expired})
      [] -> throw({:storage, :invalid_cursor})
    end
  end

  defp valid_query?(
         %{scope: scope, kind: kind, generation: generation, after: after_id, limit: limit} =
           query
       )
       when map_size(query) == 5 do
    Codec.id?(scope) and (kind == "observations" or record_kind?(kind)) and
      (is_nil(generation) or is_binary(generation)) and
      (after_id == "" or Codec.id?(after_id)) and is_integer(limit) and limit in 1..100
  end

  defp valid_query?(_), do: false

  # Rule history is written only by the rule transaction, never by a generic update.
  defp record_kind?(kind), do: kind == "rules" or kind in Update.kinds()

  defp requested_generation(_db, %{generation: nil}), do: {:ok, nil}
  defp requested_generation(_db, query), do: Codec.generation(query.generation)

  defp fetch_row(db, scope, kind, id, generation) do
    rows =
      if kind == "observations" do
        SQL.rows!(
          db,
          "SELECT document,generation FROM observations WHERE scope=? AND id=? AND generation<=?",
          [scope, id, generation]
        )
      else
        SQL.rows!(
          db,
          "SELECT document,generation FROM records WHERE scope=? AND kind=? AND id=? AND generation<=? ORDER BY generation DESC LIMIT 1",
          [scope, kind, id, generation]
        )
      end

    case rows do
      [[document, version]] when document != "null" ->
        {:ok,
         %{
           "id" => id,
           "generation" => Integer.to_string(generation),
           "record_generation" => Integer.to_string(version),
           "value" => Codec.decode!(document)
         }}

      _ ->
        {:error, :not_found}
    end
  end

  defp page(db, %{kind: "observations"} = query, generation) do
    SQL.rows!(
      db,
      "SELECT id,document,generation FROM observations WHERE scope=? AND generation<=? AND id>? ORDER BY id LIMIT ?",
      [query.scope, generation, query.after, query.limit]
    )
  end

  defp page(db, query, generation) do
    SQL.rows!(
      db,
      """
      SELECT r.id,r.document,r.generation FROM records r
      WHERE r.scope=? AND r.kind=? AND r.id>? AND r.generation<=?
      AND r.generation=(SELECT max(v.generation) FROM records v WHERE v.scope=r.scope AND v.kind=r.kind AND v.id=r.id AND v.generation<=?)
      AND r.document!='null' ORDER BY r.id LIMIT ?
      """,
      [query.scope, query.kind, query.after, generation, generation, query.limit]
    )
  end

  defp bounded(result) do
    case Codec.encode(result, 4_194_304) do
      {:ok, _} -> {:ok, result}
      _ -> {:error, :response_too_large}
    end
  end
end
