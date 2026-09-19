defmodule Wotex.Tracker.Service.ForwardQueue do
  @moduledoc false

  alias Wotex.Tracker.Service.{Codec, ForwardItem, SQL}

  @completion_fields ~w(status layer at reference)a
  @completion_statuses ~w(sent acknowledged)a
  @discard_reasons ~w(endpoint_missing endpoint_rotated authorization_revoked provider_rejected invalid_token)

  def enqueue(db, item, options) do
    transaction(db, options, fn -> stage(db, item, options) end)
  end

  @doc false
  # Stages one item inside a transaction already owned by another durable
  # admission boundary. The caller, not this function, commits or rolls back.
  def stage(db, item, options) do
    expire(db, item.scope, item.admitted_at)

    case row(db, item.scope, item.id) do
      nil -> insert(db, item, options)
      stored -> duplicate(stored, item)
    end
  end

  def claim(db, scope, now, limit, retry_after_ms, options) do
    transaction(db, options, fn ->
      expire(db, scope, now)
      exhaust(db, scope, now)

      rows =
        SQL.rows!(
          db,
          "SELECT id,digest,document,size_bytes,admitted_at,expires_at,attempts,max_attempts " <>
            "FROM forward_queue WHERE scope=? AND status='pending' AND next_attempt_at<=? " <>
            "ORDER BY admitted_at,id LIMIT ?",
          [scope, now, limit]
        )

      items = claim_rows(db, scope, now, retry_after_ms, rows)

      %{
        "schema" => "wtr.forward-claim.v1",
        "scope" => scope,
        "claimed_at" => now,
        "retry_after_ms" => retry_after_ms,
        "items" => items
      }
    end)
  end

  def claim_notifications(db, scope, now, limit, retry_after_ms, options) do
    transaction(db, options, fn ->
      expire(db, scope, now)
      exhaust(db, scope, now)

      rows =
        SQL.rows!(
          db,
          "SELECT id,digest,document,size_bytes,admitted_at,expires_at,attempts,max_attempts " <>
            "FROM forward_queue WHERE scope=? AND status='pending' AND next_attempt_at<=? " <>
            "AND json_extract(document,'$.bearer')='push' " <>
            "AND json_extract(document,'$.application_protocol')='apns' " <>
            "AND json_extract(document,'$.payload.schema')='wtr.notification-reference.v1' " <>
            "ORDER BY admitted_at,id LIMIT ?",
          [scope, now, limit]
        )

      %{
        "schema" => "wtr.forward-claim.v1",
        "scope" => scope,
        "claimed_at" => now,
        "retry_after_ms" => retry_after_ms,
        "items" => claim_rows(db, scope, now, retry_after_ms, rows)
      }
    end)
  end

  def complete(db, scope, id, identity, completion, options) do
    transaction(db, options, fn ->
      case row(db, scope, id) do
        nil -> throw({:storage, :not_found})
        stored -> complete_row(db, stored, identity, completion)
      end
    end)
  end

  def discard(db, scope, id, identity, reason, now, options) do
    transaction(db, options, fn ->
      case row(db, scope, id) do
        nil -> throw({:storage, :not_found})
        stored -> discard_row(db, stored, identity, reason, now)
      end
    end)
  end

  def status(db, scope, id) do
    case row(db, scope, id) do
      nil -> {:error, :not_found}
      stored -> {:ok, project(stored)}
    end
  end

  def cleanup(db, scope, before, options) do
    transaction(db, options, fn ->
      SQL.rows!(
        db,
        "DELETE FROM forward_queue WHERE scope=? AND status!='pending' AND settled_at<=?",
        [scope, before]
      )

      [[count]] = SQL.rows!(db, "SELECT changes()")
      %{"schema" => "wtr.forward-cleanup.v1", "scope" => scope, "removed" => count}
    end)
  end

  @doc false
  def metrics(db, scope) do
    [[items, bytes]] =
      SQL.rows!(
        db,
        "SELECT count(*),coalesce(sum(size_bytes),0) FROM forward_queue " <>
          "WHERE scope=? AND status='pending'",
        [scope]
      )

    %{depth_items: items, depth_bytes: bytes}
  end

  def completion(value) do
    with true <-
           is_map(value) and not is_struct(value) and
             Enum.sort(Map.keys(value)) == Enum.sort(@completion_fields),
         true <- value.status in @completion_statuses,
         true <- value.layer in [:none | ForwardItem.acknowledgement_layers()],
         true <- Codec.time?(value.at),
         true <- Codec.id?(value.reference),
         true <- completion_shape?(value) do
      {:ok, value}
    else
      _ -> {:error, :invalid_forward_completion}
    end
  end

  def discard_reason?(value), do: value in @discard_reasons

  defp claim_rows(db, scope, now, retry_after_ms, rows) do
    Enum.map(rows, fn [id, digest, document, bytes, _admitted, expires, attempts, maximum] ->
      attempt = attempts + 1
      retry_at = min(expires, now + retry_after_ms)

      SQL.rows!(
        db,
        "UPDATE forward_queue SET attempts=?,next_attempt_at=? " <>
          "WHERE scope=? AND id=? AND status='pending'",
        [attempt, retry_at, scope, id]
      )

      document
      |> Codec.decode!()
      |> Map.merge(%{
        "queue_identity" => digest,
        "size_bytes" => bytes,
        "expires_at" => expires,
        "attempt" => attempt,
        "maximum_attempts" => maximum,
        "retry_at" => retry_at
      })
    end)
  end

  defp insert(db, item, options) do
    document = ForwardItem.document(item)
    encoded = Codec.encode!(document)
    bytes = byte_size(encoded)
    expires = item.admitted_at + options.forward_max_age_ms

    if expires > 9_007_199_254_740_991,
      do: throw({:storage, :invalid_forward_item})

    case queue_capacity(db, item.scope, bytes, options) do
      :ok -> insert_pending(db, item, encoded, bytes, expires, options)
      :full when item.source == :reliable -> throw({:storage, :queue_full})
      :full -> insert_dropped(db, item, encoded, bytes, expires, options)
    end
  end

  defp insert_pending(db, item, encoded, bytes, expires, options) do
    table_capacity!(db, options)

    SQL.rows!(db, "INSERT INTO forward_queue VALUES(?,?,?,?,?,?,?,?,?,?,'pending',NULL,NULL)", [
      item.scope,
      item.id,
      item.identity,
      encoded,
      bytes,
      item.admitted_at,
      expires,
      0,
      item.admitted_at,
      options.forward_max_attempts
    ])

    receipt(item, "queued", nil, expires, 0, options.forward_max_attempts)
  end

  defp insert_dropped(db, item, encoded, bytes, expires, options) do
    table_capacity!(db, options)

    SQL.rows!(
      db,
      "INSERT INTO forward_queue VALUES(?,?,?,?,?,?,?,?,?,?,'discarded','overflow',?)",
      [
        item.scope,
        item.id,
        item.identity,
        encoded,
        bytes,
        item.admitted_at,
        expires,
        0,
        item.admitted_at,
        options.forward_max_attempts,
        item.admitted_at
      ]
    )

    receipt(item, "dropped", "overflow", expires, 0, options.forward_max_attempts)
  end

  defp duplicate(stored, item) do
    if stored.digest == item.identity,
      do: project(stored),
      else: throw({:storage, :forward_conflict})
  end

  defp complete_row(_db, %{digest: digest}, identity, _completion) when digest != identity,
    do: throw({:storage, :forward_conflict})

  defp complete_row(_db, %{status: "discarded"}, _identity, _completion),
    do: throw({:storage, :forward_discarded})

  defp complete_row(_db, %{status: "delivered"} = stored, _identity, completion) do
    encoded = Codec.encode!(completion_map(completion))

    if stored.outcome == encoded,
      do: project(stored),
      else: throw({:storage, :forward_conflict})
  end

  defp complete_row(_db, %{attempts: 0}, _identity, _completion),
    do: throw({:storage, :forward_not_claimed})

  defp complete_row(db, stored, _identity, completion) do
    document = Codec.decode!(stored.document)
    required = document["required_acknowledgement"]
    validate_completion!(completion, required, stored.admitted_at)
    outcome = Codec.encode!(completion_map(completion))

    SQL.rows!(
      db,
      "UPDATE forward_queue SET status='delivered',outcome=?,settled_at=? " <>
        "WHERE scope=? AND id=? AND status='pending'",
      [outcome, completion.at, stored.scope, stored.id]
    )

    project(%{stored | status: "delivered", outcome: outcome, settled_at: completion.at})
  end

  defp discard_row(_db, %{digest: digest}, identity, _reason, _now) when digest != identity,
    do: throw({:storage, :forward_conflict})

  defp discard_row(_db, %{status: "delivered"}, _identity, _reason, _now),
    do: throw({:storage, :forward_conflict})

  defp discard_row(
         _db,
         %{status: "discarded", outcome: outcome} = stored,
         _identity,
         reason,
         _now
       ) do
    if outcome == reason,
      do: project(stored),
      else: throw({:storage, :forward_conflict})
  end

  defp discard_row(_db, %{attempts: 0}, _identity, _reason, _now),
    do: throw({:storage, :forward_not_claimed})

  defp discard_row(_db, %{admitted_at: admitted}, _identity, _reason, now) when now < admitted,
    do: throw({:storage, :invalid_forward_discard})

  defp discard_row(db, stored, _identity, reason, now) do
    SQL.rows!(
      db,
      "UPDATE forward_queue SET status='discarded',outcome=?,settled_at=? " <>
        "WHERE scope=? AND id=? AND status='pending'",
      [reason, now, stored.scope, stored.id]
    )

    project(%{stored | status: "discarded", outcome: reason, settled_at: now})
  end

  defp validate_completion!(%{status: :sent, layer: :none, at: at}, "none", admitted)
       when at >= admitted,
       do: :ok

  defp validate_completion!(%{status: :acknowledged, layer: layer, at: at}, required, admitted)
       when required != "none" and at >= admitted do
    if Atom.to_string(layer) == required,
      do: :ok,
      else: throw({:storage, :acknowledgement_mismatch})
  end

  defp validate_completion!(_, _, _), do: throw({:storage, :acknowledgement_mismatch})

  defp queue_capacity(db, scope, bytes, options) do
    [[count, queued_bytes]] =
      SQL.rows!(
        db,
        "SELECT count(*),coalesce(sum(size_bytes),0) FROM forward_queue " <>
          "WHERE scope=? AND status='pending'",
        [scope]
      )

    if count + 1 <= options.forward_max_items and
         queued_bytes + bytes <= options.forward_max_bytes,
       do: :ok,
       else: :full
  end

  defp table_capacity!(db, options) do
    [[count]] = SQL.rows!(db, "SELECT count(*) FROM forward_queue")
    if count + 1 > options.max_rows, do: throw({:storage, :capacity_exceeded})
  end

  defp expire(db, scope, now) do
    SQL.rows!(
      db,
      "UPDATE forward_queue SET status='discarded',outcome='expired',settled_at=? " <>
        "WHERE scope=? AND status='pending' AND expires_at<=?",
      [now, scope, now]
    )
  end

  defp exhaust(db, scope, now) do
    SQL.rows!(
      db,
      "UPDATE forward_queue SET status='discarded',outcome='attempts_exhausted',settled_at=? " <>
        "WHERE scope=? AND status='pending' AND attempts>=max_attempts AND next_attempt_at<=?",
      [now, scope, now]
    )
  end

  defp row(db, scope, id) do
    case SQL.rows!(
           db,
           "SELECT scope,id,digest,document,size_bytes,admitted_at,expires_at,attempts," <>
             "max_attempts,next_attempt_at,status,outcome,settled_at " <>
             "FROM forward_queue WHERE scope=? AND id=?",
           [scope, id]
         ) do
      [values] -> row_map(values)
      [] -> nil
    end
  end

  defp row_map([
         scope,
         id,
         digest,
         document,
         bytes,
         admitted,
         expires,
         attempts,
         maximum,
         retry_at,
         status,
         outcome,
         settled
       ]),
       do: %{
         scope: scope,
         id: id,
         digest: digest,
         document: document,
         bytes: bytes,
         admitted_at: admitted,
         expires_at: expires,
         attempts: attempts,
         maximum_attempts: maximum,
         retry_at: retry_at,
         status: status,
         outcome: outcome,
         settled_at: settled
       }

  defp project(stored) do
    document = Codec.decode!(stored.document)

    %{
      "schema" => "wtr.forward-receipt.v1",
      "scope" => stored.scope,
      "item_id" => stored.id,
      "queue_identity" => stored.digest,
      "status" => stored.status,
      "disposition" => disposition(stored),
      "reason" => reason(stored),
      "candidate_id" => document["candidate_id"],
      "bearer" => document["bearer"],
      "application_protocol" => document["application_protocol"],
      "required_acknowledgement" => document["required_acknowledgement"],
      "size_bytes" => stored.bytes,
      "admitted_at" => stored.admitted_at,
      "expires_at" => stored.expires_at,
      "attempts" => stored.attempts,
      "maximum_attempts" => stored.maximum_attempts,
      "retry_at" => stored.retry_at,
      "completion" => decoded_outcome(stored),
      "settled_at" => stored.settled_at
    }
  end

  defp receipt(item, disposition, reason, expires, attempts, maximum) do
    %{
      "schema" => "wtr.forward-receipt.v1",
      "scope" => item.scope,
      "item_id" => item.id,
      "queue_identity" => item.identity,
      "status" => if(disposition == "queued", do: "pending", else: "discarded"),
      "disposition" => disposition,
      "reason" => reason,
      "candidate_id" => item.candidate_id,
      "bearer" => item.bearer,
      "application_protocol" => item.application_protocol,
      "required_acknowledgement" => Atom.to_string(item.required_acknowledgement),
      "size_bytes" => byte_size(Codec.encode!(ForwardItem.document(item))),
      "admitted_at" => item.admitted_at,
      "expires_at" => expires,
      "attempts" => attempts,
      "maximum_attempts" => maximum,
      "retry_at" => item.admitted_at,
      "completion" => nil,
      "settled_at" => if(disposition == "queued", do: nil, else: item.admitted_at)
    }
  end

  defp disposition(%{status: "pending"}), do: "queued"
  defp disposition(%{status: "delivered"}), do: "delivered"
  defp disposition(%{status: "discarded"}), do: "dropped"
  defp reason(%{status: "discarded", outcome: outcome}), do: outcome
  defp reason(_), do: nil

  defp decoded_outcome(%{status: "delivered", outcome: outcome}), do: Codec.decode!(outcome)
  defp decoded_outcome(_), do: nil

  defp completion_map(value),
    do: %{
      "status" => Atom.to_string(value.status),
      "layer" => Atom.to_string(value.layer),
      "at" => value.at,
      "reference" => value.reference
    }

  defp completion_shape?(%{status: :sent, layer: :none}), do: true

  defp completion_shape?(%{status: :acknowledged, layer: layer}),
    do: layer in ForwardItem.acknowledgement_layers()

  defp completion_shape?(_), do: false

  defp transaction(db, options, operation) do
    SQL.execute!(db, "BEGIN IMMEDIATE")

    result =
      try do
        result = operation.()
        fault!(options, :forward_before_commit)

        case SQL.boundary(fn -> SQL.execute!(db, "COMMIT") end) do
          :ok -> result
          {:error, _} -> throw({:storage, :unknown})
        end
      after
        SQL.rollback(db)
      end

    case options.fault.(:forward_after_commit) do
      :ok -> {:ok, result}
      :abort -> {:error, :unknown}
      :crash -> exit(:injected_crash)
    end
  end

  defp fault!(options, phase) do
    case options.fault.(phase) do
      :ok -> :ok
      :abort -> throw({:storage, :injected_failure})
      :crash -> exit(:injected_crash)
    end
  end
end
