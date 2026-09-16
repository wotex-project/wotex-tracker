defmodule Wotex.Tracker.Service.Transaction do
  @moduledoc false

  alias Wotex.Tracker.Observation
  alias Wotex.Tracker.Service.{Authority, Codec, Operation, SQL}

  @retention 604_800_000

  def mutate(db, update, options) do
    SQL.execute!(db, "BEGIN IMMEDIATE")

    try do
      update = %{update | now: Authority.now(options, update.now)}
      Authority.mutation!(db, options.credentials, update)
      result = admission(db, update, options)
      fault!(options, :before_commit)

      Authority.fresh!(options.credentials, update, Authority.now(options, update.now))

      case SQL.boundary(fn -> SQL.execute!(db, "COMMIT") end) do
        :ok -> :ok
        {:error, _} -> throw({:storage, :unknown})
      end

      acknowledge(options, result)
    after
      SQL.rollback(db)
    end
  end

  def operation(db, scope, principal, id, now) do
    case SQL.rows!(
           db,
           "SELECT result, expires_at FROM operations WHERE scope=? AND principal=? AND id=?",
           [scope, principal, id]
         ) do
      [[result, expires]] when now < expires -> {:ok, Codec.decode!(result)}
      [[_, _]] -> {:error, :operation_expired}
      [] -> {:error, :not_found}
    end
  end

  def generation(db, scope) do
    case SQL.rows!(db, "SELECT generation FROM scopes WHERE scope=?", [scope]) do
      [[generation]] -> generation
      [] -> 0
    end
  end

  defp admission(db, update, options) do
    digest =
      Operation.digest(
        update.request,
        update.expected_generation,
        observation_identity(update.observation)
      )

    case Operation.lookup(
           db,
           update.scope,
           update.principal,
           update.operation_id,
           digest,
           update.now
         ) do
      {:ok, result} -> result
      :new -> prepare_new(db, update, options, digest)
    end
  end

  defp prepare_new(db, update, options, digest) do
    generation = generation(db, update.scope)

    if Integer.to_string(generation) != update.expected_generation,
      do: throw({:storage, :conflict})

    capacity!(db, "operations", 1, options.max_rows)

    result =
      if duplicate?(db, update) do
        result(update, generation, "duplicate", nil)
      else
        if generation >= 9_223_372_036_854_775_806, do: throw({:storage, :capacity_exceeded})
        write_new(db, update, generation + 1, options)
      end

    SQL.rows!(db, "INSERT INTO operations VALUES(?,?,?,?,?,?)", [
      update.scope,
      update.principal,
      update.operation_id,
      digest,
      Codec.encode!(result),
      update.now + @retention
    ])

    result
  end

  defp duplicate?(_db, %{observation: nil}), do: false

  defp duplicate?(db, update) do
    {:ok, digest} = Observation.identity(update.observation)

    case SQL.rows!(db, "SELECT digest FROM observations WHERE scope=? AND id=?", [
           update.scope,
           update.observation.id
         ]) do
      [[^digest]] -> true
      [[_]] -> throw({:storage, :observation_conflict})
      [] -> false
    end
  end

  defp observation_identity(nil), do: nil

  defp observation_identity(observation) do
    {:ok, identity} = Observation.identity(observation)
    identity
  end

  defp write_new(db, update, generation, options) do
    capacity!(db, "records", length(update.records), options.max_rows)
    capacity!(db, "events", length(update.events), options.max_rows)
    write_observation(db, update, generation, options)

    Enum.each(update.records, fn record ->
      SQL.rows!(db, "INSERT INTO records VALUES(?,?,?,?,?)", [
        update.scope,
        record.kind,
        record.id,
        generation,
        Codec.encode!(record.value)
      ])
    end)

    # Tombstones and replacement records belong to this same transaction.
    fault!(options, :stale_cleanup)

    Enum.each(update.events, fn event ->
      SQL.rows!(db, "INSERT INTO events(scope,generation,created_at,document) VALUES(?,?,?,?)", [
        update.scope,
        generation,
        update.now,
        Codec.encode!(event)
      ])
    end)

    publication = write_publication(db, update, generation, options)

    SQL.rows!(
      db,
      "INSERT INTO scopes VALUES(?,?) ON CONFLICT(scope) DO UPDATE SET generation=excluded.generation",
      [update.scope, generation]
    )

    result(update, generation, "accepted", publication)
  end

  defp write_observation(_db, %{observation: nil}, _generation, _options), do: :ok

  defp write_observation(db, update, generation, options) do
    capacity!(db, "observations", 1, options.max_rows)
    {:ok, digest} = Observation.identity(update.observation)
    {:ok, document} = Observation.to_map(update.observation)

    SQL.rows!(db, "INSERT INTO observations VALUES(?,?,?,?,?)", [
      update.scope,
      update.observation.id,
      digest,
      generation,
      Codec.encode!(document)
    ])
  end

  defp write_publication(_db, %{publication: nil}, _generation, _options), do: nil

  defp write_publication(db, update, generation, options) do
    capacity!(db, "publications", 1, options.max_rows)
    publication = update.publication

    SQL.rows!(
      db,
      "UPDATE publications SET status='superseded' WHERE scope=? AND thing_id=? AND status='pending'",
      [update.scope, publication.thing_id]
    )

    document = %{"td" => publication.td, "deployment_id" => publication.deployment_id}

    SQL.rows!(db, "INSERT INTO publications VALUES(?,?,?,?,?,'pending','pending')", [
      update.scope,
      publication.thing_id,
      generation,
      update.operation_id,
      Codec.encode!(document)
    ])

    %{
      "status" => "pending",
      "thing_id" => publication.thing_id,
      "generation" => Integer.to_string(generation)
    }
  end

  defp result(update, generation, disposition, publication) do
    %{
      "outcome" => "committed",
      "operation_id" => update.operation_id,
      "generation" => Integer.to_string(generation),
      "disposition" => disposition,
      "publication" => publication
    }
    |> then(fn result ->
      if update.response, do: Map.put(result, "data", update.response), else: result
    end)
  end

  defp capacity!(db, table, count, maximum) do
    # `table` is a compile-time call-site literal, never caller SQL.
    [[current]] = SQL.rows!(db, "SELECT count(*) FROM #{table}")
    if current + count > maximum, do: throw({:storage, :capacity_exceeded})
  end

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
