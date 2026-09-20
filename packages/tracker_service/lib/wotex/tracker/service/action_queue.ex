defmodule Wotex.Tracker.Service.ActionQueue do
  @moduledoc false

  alias Wotex.Tracker.Service.{ActionIntent, Authority, Codec, Operation, SQL}

  @operation_retention_ms 604_800_000
  @completion_statuses ~w(accepted failed unknown)a
  @classifications ~w(protocol_ok protocol_accepted runtime_construction runtime_selection runtime_credentials transport_unknown dispatch_unknown)

  def admit(db, intent, options) do
    transaction(db, options, :action_before_commit, :action_after_commit, fn ->
      now = Authority.now(options, intent.admitted_at)
      authorize!(db, options, intent, now)

      request = request(intent)
      digest = Operation.digest(request, intent.thing_generation, nil)

      case Operation.lookup(db, intent.scope, intent.access.principal, intent.id, digest, now) do
        {:ok, result} ->
          result

        :new ->
          current_thing!(db, intent)
          insert(db, intent, digest, now, options)
      end
    end)
  end

  def claim(db, scope, now, limit, options) do
    transaction(db, options, :action_claim_before_commit, nil, fn ->
      rows =
        SQL.rows!(
          db,
          "SELECT principal,id,digest,document FROM action_intents " <>
            "WHERE scope=? AND status='pending' AND eligible_at<=? " <>
            "ORDER BY admitted_at,id LIMIT ?",
          [scope, now, limit]
        )

      {items, denied} = claim_rows(db, scope, rows, now, options)

      %{
        "schema" => "wtr.action-claim.v1",
        "scope" => scope,
        "claimed_at" => now,
        "denied" => denied,
        "items" => Enum.reverse(items)
      }
    end)
  end

  def settle(db, scope, principal, id, identity, completion, options) do
    transaction(db, options, :action_settle_before_commit, nil, fn ->
      stored = row!(db, scope, principal, id)

      cond do
        stored.digest != identity ->
          throw({:storage, :action_conflict})

        stored.status == Atom.to_string(completion.status) and
            stored.outcome == Codec.encode!(completion_map(completion)) ->
          project(stored)

        stored.status != "unknown" ->
          throw({:storage, :action_conflict})

        true ->
          settle_row(db, stored, completion)
      end
    end)
  end

  def authorized_status(db, access, id, now, options) do
    SQL.execute!(db, "BEGIN")

    try do
      now = Authority.now(options, now)
      Authority.check!(db, options.credentials, access, access.scope, "interact", now)

      case row(db, access.scope, access.principal, id) do
        nil -> {:error, :not_found}
        stored -> {:ok, project(stored)}
      end
    after
      SQL.rollback(db)
    end
  end

  def completion(value) do
    with true <-
           is_map(value) and not is_struct(value) and
             Enum.sort(Map.keys(value)) == ~w(at classification status)a,
         true <- value.status in @completion_statuses,
         true <- value.classification in @classifications,
         true <- Codec.time?(value.at),
         true <- completion_shape?(value) do
      {:ok, value}
    else
      _ -> {:error, :invalid_action_completion}
    end
  end

  defp insert(db, intent, digest, now, options) do
    table_capacity!(db, "operations", options)
    table_capacity!(db, "action_intents", options)
    document = Codec.encode!(ActionIntent.document(intent))

    SQL.rows!(
      db,
      "INSERT INTO action_intents VALUES(?,?,?,?,?,?,?,?,?,'pending',NULL,NULL,NULL)",
      [
        intent.scope,
        intent.access.principal,
        intent.id,
        intent.identity,
        document,
        intent.thing_id,
        String.to_integer(intent.thing_generation),
        intent.admitted_at,
        now
      ]
    )

    result = %{
      "outcome" => "committed",
      "operation_id" => intent.id,
      "generation" => intent.thing_generation,
      "disposition" => "queued",
      "data" => %{"action_id" => intent.id, "status" => "queued"}
    }

    SQL.rows!(db, "INSERT INTO operations VALUES(?,?,?,?,?,?)", [
      intent.scope,
      intent.access.principal,
      intent.id,
      digest,
      Codec.encode!(result),
      now + @operation_retention_ms
    ])

    Authority.check!(
      db,
      options.credentials,
      intent.access,
      intent.scope,
      "interact",
      Authority.now(options, now)
    )

    result
  end

  defp claim_row(db, scope, [principal, id, digest, document], now, options) do
    with {:ok, intent} <- document |> Codec.decode!() |> ActionIntent.restore(),
         true <- intent.scope == scope and intent.access.principal == principal,
         true <- intent.identity == digest,
         :ok <- reauthorize(db, options, intent, now),
         {:ok, td} <- current_thing(db, intent) do
      outcome = Codec.encode!(%{"classification" => "dispatch_started"})

      SQL.rows!(
        db,
        "UPDATE action_intents SET status='unknown',outcome=?,claimed_at=?,settled_at=? " <>
          "WHERE scope=? AND principal=? AND id=? AND status='pending'",
        [outcome, now, now, scope, principal, id]
      )

      {:ok,
       %{
         "scope" => scope,
         "principal" => principal,
         "operation_id" => id,
         "intent_identity" => digest,
         "thing_id" => intent.thing_id,
         "thing_generation" => intent.thing_generation,
         "action" => intent.name,
         "input" => intent.input,
         "thing_description" => td
       }}
    else
      _ ->
        deny(db, scope, principal, id, now)
        :denied
    end
  end

  defp claim_rows(db, scope, rows, now, options) do
    Enum.reduce(rows, {[], 0}, fn row, {items, denied} ->
      case claim_row(db, scope, row, now, options) do
        {:ok, item} -> {[item | items], denied}
        :denied -> {items, denied + 1}
      end
    end)
  end

  defp deny(db, scope, principal, id, now) do
    outcome = Codec.encode!(%{"classification" => "authorization_or_revision_changed"})

    SQL.rows!(
      db,
      "UPDATE action_intents SET status='denied',outcome=?,settled_at=? " <>
        "WHERE scope=? AND principal=? AND id=? AND status='pending'",
      [outcome, now, scope, principal, id]
    )
  end

  defp settle_row(db, stored, completion) do
    status = Atom.to_string(completion.status)
    outcome = Codec.encode!(completion_map(completion))

    SQL.rows!(
      db,
      "UPDATE action_intents SET status=?,outcome=?,settled_at=? " <>
        "WHERE scope=? AND principal=? AND id=? AND status='unknown'",
      [status, outcome, completion.at, stored.scope, stored.principal, stored.id]
    )

    project(%{stored | status: status, outcome: outcome, settled_at: completion.at})
  end

  defp reauthorize(db, options, intent, now) do
    authorize!(db, options, intent, now)
  catch
    {:storage, reason} when reason in [:unauthorized, :forbidden] -> {:error, reason}
  end

  defp authorize!(db, options, intent, now),
    do:
      Authority.check!(
        db,
        options.credentials,
        intent.access,
        intent.scope,
        "interact",
        now
      )

  defp current_thing!(db, intent) do
    case current_thing(db, intent) do
      {:ok, td} -> td
      {:error, reason} -> throw({:storage, reason})
    end
  end

  defp current_thing(db, intent) do
    expected_generation = String.to_integer(intent.thing_generation)

    case SQL.rows!(
           db,
           "SELECT generation,document FROM records " <>
             "WHERE scope=? AND kind='things' AND id=? ORDER BY generation DESC LIMIT 1",
           [intent.scope, intent.thing_id]
         ) do
      [[^expected_generation, document]] ->
        value = Codec.decode!(document)
        td = value["public"]

        if is_map(td) and Codec.digest(td) == intent.thing_identity,
          do: {:ok, td},
          else: {:error, :revision_mismatch}

      _ ->
        {:error, :revision_mismatch}
    end
  end

  defp row!(db, scope, principal, id) do
    case row(db, scope, principal, id) do
      nil -> throw({:storage, :not_found})
      stored -> stored
    end
  end

  defp row(db, scope, principal, id) do
    case SQL.rows!(
           db,
           "SELECT scope,principal,id,digest,document,thing_id,thing_generation," <>
             "admitted_at,eligible_at,status,outcome,claimed_at,settled_at " <>
             "FROM action_intents WHERE scope=? AND principal=? AND id=?",
           [scope, principal, id]
         ) do
      [values] -> row_map(values)
      [] -> nil
    end
  end

  defp row_map([
         scope,
         principal,
         id,
         digest,
         document,
         thing,
         generation,
         admitted,
         eligible,
         status,
         outcome,
         claimed,
         settled
       ]),
       do: %{
         scope: scope,
         principal: principal,
         id: id,
         digest: digest,
         document: document,
         thing_id: thing,
         thing_generation: generation,
         admitted_at: admitted,
         eligible_at: eligible,
         status: status,
         outcome: outcome,
         claimed_at: claimed,
         settled_at: settled
       }

  defp project(stored) do
    document = Codec.decode!(stored.document)

    %{
      "schema" => "wtr.action-status.v1",
      "operation_id" => stored.id,
      "thing" => %{
        "id" => stored.thing_id,
        "generation" => Integer.to_string(stored.thing_generation)
      },
      "action" => document["action"],
      "status" => public_status(stored.status),
      "admitted_at" => stored.admitted_at,
      "claimed_at" => stored.claimed_at,
      "settled_at" => stored.settled_at,
      "outcome" => decode_outcome(stored.outcome),
      "physical_effect" => physical_effect(stored.status)
    }
  end

  defp request(intent),
    do: %{
      "operation" => "invoke_action",
      "thing_id" => intent.thing_id,
      "action" => intent.name,
      "input" => intent.input
    }

  defp public_status("pending"), do: "queued"
  defp public_status(status), do: status
  defp decode_outcome(nil), do: nil
  defp decode_outcome(outcome), do: Codec.decode!(outcome)

  defp physical_effect(status) when status in ["pending", "denied", "failed"],
    do: "not_dispatched"

  defp physical_effect(_), do: "unknown"

  defp completion_map(value),
    do: %{
      "classification" => value.classification,
      "completed_at" => value.at
    }

  defp completion_shape?(%{status: :accepted, classification: classification}),
    do: classification in ~w(protocol_ok protocol_accepted)

  defp completion_shape?(%{status: :failed, classification: classification}),
    do: classification in ~w(runtime_construction runtime_selection runtime_credentials)

  defp completion_shape?(%{status: :unknown, classification: classification}),
    do: classification in ~w(transport_unknown dispatch_unknown)

  defp table_capacity!(db, table, options) do
    # `table` is a compile-time call-site literal, never caller SQL.
    [[count]] = SQL.rows!(db, "SELECT count(*) FROM #{table}")
    if count + 1 > options.max_rows, do: throw({:storage, :capacity_exceeded})
  end

  defp transaction(db, options, before_phase, after_phase, operation) do
    SQL.execute!(db, "BEGIN IMMEDIATE")

    result =
      try do
        result = operation.()
        fault!(options, before_phase)

        case SQL.boundary(fn -> SQL.execute!(db, "COMMIT") end) do
          :ok -> result
          {:error, _} -> throw({:storage, :unknown})
        end
      after
        SQL.rollback(db)
      end

    acknowledge(options, after_phase, result)
  end

  defp fault!(options, phase) do
    case options.fault.(phase) do
      :ok -> :ok
      :abort -> throw({:storage, :injected_failure})
      :crash -> exit(:injected_crash)
    end
  end

  defp acknowledge(_, nil, result), do: {:ok, result}

  defp acknowledge(options, phase, result) do
    case options.fault.(phase) do
      :ok -> {:ok, result}
      :abort -> {:error, :unknown}
      :crash -> exit(:injected_crash)
    end
  end
end
