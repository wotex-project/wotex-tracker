defmodule Wotex.Tracker.Service.DataDeletion do
  @moduledoc false

  alias Wotex.Tracker.Service.{Access, AccessAudit, Authority, Codec, Operation, SQL, Transaction}

  @operation_retention_ms 604_800_000
  @confirmation "delete retained domain data"

  def confirmation, do: @confirmation

  def admit(%{"expected_generation" => generation, "confirmation" => @confirmation} = request)
      when map_size(request) == 2 do
    if match?({:ok, _}, Codec.generation(generation)),
      do: :ok,
      else: {:error, :invalid_request}
  end

  def admit(_), do: {:error, :invalid_request}

  def status(db, %Access{} = access, now, options) do
    SQL.execute!(db, "BEGIN")

    try do
      Authority.check!(db, options.credentials, access, access.scope, "admin", now)
      generation = Transaction.generation(db, access.scope)

      {:ok,
       %{
         "schema" => "wtr.privacy.v1",
         "generation" => Integer.to_string(generation),
         "retained" => retained(db, access.scope),
         "preserved_on_deletion" => preserved(db, access.scope),
         "last_deletion" => last_deletion(db, access.scope),
         "policy" => policy()
       }}
    after
      SQL.rollback(db)
    end
  end

  def status(_, _, _, _), do: {:error, :invalid_query}

  def delete(db, %Access{} = access, operation, request, now, options) do
    with :ok <- admit(request),
         true <- Codec.id?(operation) and Codec.time?(now) do
      SQL.execute!(db, "BEGIN IMMEDIATE")

      try do
        now = Authority.now(options, now)
        Authority.check!(db, options.credentials, access, access.scope, "admin", now)
        digest = Operation.digest(intent(request), request["expected_generation"], nil)

        case Operation.lookup(db, access.scope, access.principal, operation, digest, now) do
          {:ok, result} ->
            {:ok, result}

          :new ->
            delete_new(db, access, operation, request, digest, now, options)
        end
      after
        SQL.rollback(db)
      end
    else
      _ -> {:error, :invalid_request}
    end
  end

  def delete(_, _, _, _, _, _), do: {:error, :invalid_request}

  defp delete_new(db, access, operation, request, digest, now, options) do
    generation = Transaction.generation(db, access.scope)

    if Integer.to_string(generation) != request["expected_generation"],
      do: throw({:storage, :conflict})

    if generation >= 9_223_372_036_854_775_806,
      do: throw({:storage, :capacity_exceeded})

    removed = retained(db, access.scope)
    preserved = preserved(db, access.scope)
    next_generation = generation + 1

    delete_rows(db, access.scope)
    write_marker(db, access.scope, next_generation, now, removed)
    write_event(db, access.scope, next_generation, now)
    write_generation(db, access.scope, next_generation)

    result =
      receipt(operation, next_generation, now, removed, preserved)

    SQL.rows!(db, "INSERT INTO operations VALUES(?,?,?,?,?,?)", [
      access.scope,
      access.principal,
      operation,
      digest,
      Codec.encode!(result),
      now + @operation_retention_ms
    ])

    fault!(options, :before_commit)

    Authority.check!(
      db,
      options.credentials,
      access,
      access.scope,
      "admin",
      Authority.now(options, now)
    )

    case SQL.boundary(fn -> SQL.execute!(db, "COMMIT") end) do
      :ok -> acknowledge(options, result)
      {:error, _} -> throw({:storage, :unknown})
    end
  end

  defp retained(db, scope),
    do: %{
      "observations" => count(db, "observations", scope),
      "record_versions" => count_where(db, "records", "kind!='access'", scope),
      "events" => count(db, "events", scope),
      "publications" => count(db, "publications", scope),
      "queued_deliveries" => count(db, "forward_queue", scope),
      "rule_states" => count(db, "rule_states", scope),
      "rule_event_intents" => count(db, "rule_event_intents", scope),
      "operation_receipts" => count(db, "operations", scope)
    }

  defp preserved(db, scope),
    do: %{
      "credential_revocations" => count_where(db, "records", "kind='access'", scope),
      "successful_access_entries" => count(db, "access_audit", scope)
    }

  defp count(db, table, scope) do
    [[count]] = SQL.rows!(db, "SELECT count(*) FROM #{table} WHERE scope=?", [scope])
    count
  end

  defp count_where(db, table, condition, scope) do
    [[count]] =
      SQL.rows!(db, "SELECT count(*) FROM #{table} WHERE scope=? AND #{condition}", [scope])

    count
  end

  defp last_deletion(db, scope) do
    case SQL.rows!(
           db,
           "SELECT document FROM records WHERE scope=? AND kind='privacy' AND id='domain-data' ORDER BY generation DESC LIMIT 1",
           [scope]
         ) do
      [[document]] -> Codec.decode!(document)
      [] -> nil
    end
  end

  defp policy,
    do: %{
      "domain_data" => "retained_until_administrator_deletion",
      "deletion_scope" => "all_retained_domain_data_in_scope",
      "credential_revocations" => "preserved_for_access_control",
      "successful_access_audit" => %{
        "retention_ms" => AccessAudit.retention_ms(),
        "maximum_entries" => AccessAudit.maximum_entries()
      },
      "backups" => "outside_managed_primary_store",
      "offline_exports" => "outside_managed_primary_store",
      "remote_publications" => "outside_managed_primary_store"
    }

  defp delete_rows(db, scope) do
    for table <-
          ~w(observations events publications forward_queue rule_states rule_event_intents operations) do
      SQL.rows!(db, "DELETE FROM #{table} WHERE scope=?", [scope])
    end

    SQL.rows!(db, "DELETE FROM records WHERE scope=? AND kind!='access'", [scope])
  end

  defp write_marker(db, scope, generation, now, removed) do
    marker = %{
      "schema" => "wtr.privacy-deletion.v1",
      "deleted_at" => now,
      "generation" => Integer.to_string(generation),
      "removed" => removed
    }

    SQL.rows!(db, "INSERT INTO records VALUES(?,'privacy','domain-data',?,?)", [
      scope,
      generation,
      Codec.encode!(marker)
    ])
  end

  defp write_event(db, scope, generation, now) do
    event = %{
      "type" => "privacy.data_deleted",
      "data" => %{"id" => "domain-data", "action" => "deleted"}
    }

    SQL.rows!(db, "INSERT INTO events(scope,generation,created_at,document) VALUES(?,?,?,?)", [
      scope,
      generation,
      now,
      Codec.encode!(event)
    ])
  end

  defp write_generation(db, scope, generation),
    do:
      SQL.rows!(
        db,
        "INSERT INTO scopes VALUES(?,?) ON CONFLICT(scope) DO UPDATE SET generation=excluded.generation",
        [scope, generation]
      )

  defp receipt(operation, generation, now, removed, preserved),
    do: %{
      "outcome" => "committed",
      "operation_id" => operation,
      "generation" => Integer.to_string(generation),
      "disposition" => "accepted",
      "publication" => nil,
      "data" => %{
        "schema" => "wtr.domain-data-deletion.v1",
        "action" => "deleted_retained_domain_data",
        "deleted_at" => now,
        "removed" => removed,
        "preserved" => preserved,
        "backups" => "not_deleted",
        "offline_exports" => "not_deleted",
        "remote_publications" => "not_deleted"
      }
    }

  defp intent(request), do: %{"operation" => "delete_domain_data", "body" => request}

  defp fault!(options, phase) do
    case options.fault.(phase) do
      :ok -> :ok
      :abort -> throw({:storage, :injected_failure})
      :crash -> exit(:injected_crash)
    end
  end

  defp acknowledge(options, result) do
    case options.fault.(:after_commit) do
      :ok -> {:ok, result}
      :abort -> {:error, :unknown}
      :crash -> exit(:injected_crash)
    end
  end
end
