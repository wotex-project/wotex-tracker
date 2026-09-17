defmodule Wotex.Tracker.Service.RuleStore do
  @moduledoc false

  alias Wotex.Tracker.Service.{Codec, RuleEvent, RuleTransition, SQL, Transaction}

  @retired "SELECT 1 FROM records p WHERE p.scope=s.scope AND p.kind='policies' " <>
             "AND p.id=s.rule_id AND p.document='null' AND p.generation=(" <>
             "SELECT max(q.generation) FROM records q " <>
             "WHERE q.scope=p.scope AND q.kind='policies' AND q.id=p.id)"

  def commit(db, transition, options) do
    transaction(db, options, fn ->
      db
      |> state_row(transition.scope, transition.kind, transition.rule_id)
      |> commit_state(db, transition, options)
    end)
  end

  def commit_event(db, intent, options) do
    transaction(db, options, fn ->
      case event_row(db, intent.scope, RuleEvent.event_identity(intent)) do
        nil -> write_event(db, intent, options)
        stored -> duplicate_event(stored, intent)
      end
    end)
  end

  defp commit_state(nil, db, %{expected_state_identity: nil} = transition, options),
    do: write(db, transition, options)

  defp commit_state(nil, _db, _transition, _options),
    do: throw({:storage, :rule_conflict})

  defp commit_state(%{state_identity: identity} = stored, db, transition, _options)
       when identity == transition.state_identity,
       do: duplicate(db, stored, transition)

  defp commit_state(%{state_identity: identity}, db, transition, options)
       when identity == transition.expected_state_identity,
       do: write(db, transition, options)

  defp commit_state(_stored, _db, _transition, _options),
    do: throw({:storage, :rule_conflict})

  # Writes rule state inside an already admitted update transaction and generation.
  def stage(db, transitions, generation, options) do
    Enum.each(transitions, fn transition ->
      case state_row(db, transition.scope, transition.kind, transition.rule_id) do
        nil when is_nil(transition.expected_state_identity) -> :ok
        %{state_identity: identity} when identity == transition.expected_state_identity -> :ok
        _ -> throw({:storage, :conflict})
      end

      write_at(db, transition, generation, options)
    end)
  end

  def status(db, scope, kind, rule_id) do
    case state_row(db, scope, kind, rule_id) do
      nil -> {:error, :not_found}
      stored -> {:ok, project_state(stored, retired?(db, scope, rule_id))}
    end
  end

  # A rule whose public definition was deleted keeps its history but is not scheduled.
  def scheduled(db, limit) when is_integer(limit) and limit in 1..1_024 do
    rows =
      SQL.rows!(
        db,
        "SELECT s.scope,s.kind,s.rule_id,s.state_identity,s.document FROM rule_states s " <>
          "WHERE s.kind IN ('heartbeat','battery','transport_degradation') AND NOT EXISTS (" <>
          @retired <>
          ") ORDER BY s.scope,s.kind,s.rule_id LIMIT ?",
        [limit + 1]
      )

    if length(rows) > limit do
      {:error, :capacity_exceeded}
    else
      {:ok,
       Enum.map(rows, fn [scope, kind, rule_id, identity, document] ->
         %{
           "scope" => scope,
           "kind" => kind,
           "rule_id" => rule_id,
           "state_identity" => identity,
           "state" => Codec.decode!(document)
         }
       end)}
    end
  end

  def scheduled(_, _), do: {:error, :invalid_query}

  def event(db, scope, id) do
    case event_row(db, scope, id) do
      nil -> {:error, :not_found}
      stored -> {:ok, project_event(stored)}
    end
  end

  defp duplicate_event(stored, intent) do
    if stored.digest == Codec.digest(intent.event) and stored.kind == intent.kind and
         stored.rule_id == intent.rule_id and stored.mode == intent.mode and
         stored.action == intent.action do
      event_receipt(stored.generation, intent, "duplicate", "duplicate")
    else
      throw({:storage, :rule_event_conflict})
    end
  end

  defp write_event(db, intent, options) do
    generation = Transaction.generation(db, intent.scope)
    if generation >= 9_223_372_036_854_775_806, do: throw({:storage, :capacity_exceeded})
    next_generation = generation + 1
    capacity!(db, "rule_event_intents", 1, options.max_rows)
    capacity!(db, "events", 1, options.max_rows)
    id = RuleEvent.event_identity(intent)
    document = Codec.encode!(intent.event)

    SQL.rows!(db, "INSERT INTO rule_event_intents VALUES(?,?,?,?,?,?,?,?,?,?)", [
      intent.scope,
      id,
      Codec.digest(intent.event),
      intent.kind,
      intent.rule_id,
      next_generation,
      intent.evaluated_at,
      document,
      intent.mode,
      intent.action
    ])

    envelope = %{"type" => "tracker.event", "data" => intent.event}

    SQL.rows!(db, "INSERT INTO events(scope,generation,created_at,document) VALUES(?,?,?,?)", [
      intent.scope,
      next_generation,
      intent.evaluated_at,
      Codec.encode!(envelope)
    ])

    SQL.rows!(
      db,
      "INSERT INTO scopes VALUES(?,?) ON CONFLICT(scope) DO UPDATE SET generation=excluded.generation",
      [intent.scope, next_generation]
    )

    event_receipt(next_generation, intent, "accepted", "recorded")
  end

  defp duplicate(db, stored, transition) do
    if stored.transition_identity == transition.identity and event_duplicate?(db, transition) do
      event_disposition = if(transition.event, do: "duplicate", else: "none")
      receipt(stored, transition, "duplicate", event_disposition)
    else
      throw({:storage, :rule_conflict})
    end
  end

  defp event_duplicate?(_db, %{event: nil}), do: true

  defp event_duplicate?(db, transition) do
    case event_row(db, transition.scope, RuleTransition.event_identity(transition)) do
      %{digest: digest} -> digest == Codec.digest(transition.event)
      nil -> false
    end
  end

  defp write(db, transition, options) do
    generation = Transaction.generation(db, transition.scope)
    if generation >= 9_223_372_036_854_775_806, do: throw({:storage, :capacity_exceeded})
    next_generation = generation + 1
    event_disposition = write_at(db, transition, next_generation, options)

    SQL.rows!(
      db,
      "INSERT INTO scopes VALUES(?,?) ON CONFLICT(scope) DO UPDATE SET generation=excluded.generation",
      [transition.scope, next_generation]
    )

    receipt(
      %{
        generation: next_generation,
        state_identity: transition.state_identity,
        transition_identity: transition.identity
      },
      transition,
      "accepted",
      event_disposition
    )
  end

  defp write_at(db, transition, next_generation, options) do
    event_disposition = prepare_event(db, transition)
    state_insert = is_nil(state_row(db, transition.scope, transition.kind, transition.rule_id))
    capacity!(db, "rule_states", if(state_insert, do: 1, else: 0), options.max_rows)
    capacity!(db, "records", 1, options.max_rows)

    SQL.rows!(
      db,
      "INSERT INTO rule_states VALUES(?,?,?,?,?,?,?,?) " <>
        "ON CONFLICT(scope,kind,rule_id) DO UPDATE SET " <>
        "state_identity=excluded.state_identity,document=excluded.document," <>
        "generation=excluded.generation,evaluated_at=excluded.evaluated_at," <>
        "transition_identity=excluded.transition_identity",
      [
        transition.scope,
        transition.kind,
        transition.rule_id,
        transition.state_identity,
        Codec.encode!(transition.document),
        next_generation,
        transition.evaluated_at,
        transition.identity
      ]
    )

    SQL.rows!(db, "INSERT INTO records VALUES(?,?,?,?,?)", [
      transition.scope,
      "rules",
      transition.record_id,
      next_generation,
      Codec.encode!(transition.document)
    ])

    write_event(db, transition, next_generation, event_disposition, options)
    event_disposition
  end

  defp retired?(db, scope, rule_id) do
    SQL.rows!(
      db,
      "SELECT 1 FROM (SELECT ? AS scope, ? AS rule_id) s WHERE EXISTS (" <> @retired <> ")",
      [
        scope,
        rule_id
      ]
    ) != []
  end

  defp prepare_event(_db, %{event: nil}), do: "none"

  defp prepare_event(db, transition) do
    id = RuleTransition.event_identity(transition)
    digest = Codec.digest(transition.event)

    case event_row(db, transition.scope, id) do
      nil -> "recorded"
      %{digest: ^digest} -> "duplicate"
      _ -> throw({:storage, :rule_event_conflict})
    end
  end

  defp write_event(_db, %{event: nil}, _generation, _disposition, _options), do: :ok
  defp write_event(_db, _transition, _generation, "duplicate", _options), do: :ok

  defp write_event(db, transition, generation, "recorded", options) do
    capacity!(db, "rule_event_intents", 1, options.max_rows)
    capacity!(db, "events", 1, options.max_rows)
    id = RuleTransition.event_identity(transition)
    document = Codec.encode!(transition.event)

    SQL.rows!(db, "INSERT INTO rule_event_intents VALUES(?,?,?,?,?,?,?,?,?,?)", [
      transition.scope,
      id,
      Codec.digest(transition.event),
      transition.kind,
      transition.rule_id,
      generation,
      transition.evaluated_at,
      document,
      transition.mode,
      transition.action
    ])

    envelope = %{"type" => "tracker.event", "data" => transition.event}

    SQL.rows!(db, "INSERT INTO events(scope,generation,created_at,document) VALUES(?,?,?,?)", [
      transition.scope,
      generation,
      transition.evaluated_at,
      Codec.encode!(envelope)
    ])
  end

  defp state_row(db, scope, kind, rule_id) do
    case SQL.rows!(
           db,
           "SELECT state_identity,document,generation,evaluated_at,transition_identity " <>
             "FROM rule_states WHERE scope=? AND kind=? AND rule_id=?",
           [scope, kind, rule_id]
         ) do
      [[state_identity, document, generation, evaluated_at, transition_identity]] ->
        %{
          scope: scope,
          kind: kind,
          rule_id: rule_id,
          state_identity: state_identity,
          document: document,
          generation: generation,
          evaluated_at: evaluated_at,
          transition_identity: transition_identity
        }

      [] ->
        nil
    end
  end

  defp event_row(db, scope, id) do
    case SQL.rows!(
           db,
           "SELECT digest,kind,rule_id,generation,created_at,document,mode,action " <>
             "FROM rule_event_intents WHERE scope=? AND id=?",
           [scope, id]
         ) do
      [[digest, kind, rule_id, generation, created_at, document, mode, action]] ->
        %{
          scope: scope,
          id: id,
          digest: digest,
          kind: kind,
          rule_id: rule_id,
          generation: generation,
          created_at: created_at,
          document: document,
          mode: mode,
          action: action
        }

      [] ->
        nil
    end
  end

  defp project_state(stored, retired),
    do: %{
      "retired" => retired,
      "schema" => "wtr.rule-state.v1",
      "scope" => stored.scope,
      "kind" => stored.kind,
      "rule_id" => stored.rule_id,
      "state_identity" => stored.state_identity,
      "transition_identity" => stored.transition_identity,
      "generation" => Integer.to_string(stored.generation),
      "evaluated_at" => stored.evaluated_at,
      "state" => Codec.decode!(stored.document)
    }

  defp project_event(stored),
    do: %{
      "schema" => "wtr.rule-event-intent.v1",
      "scope" => stored.scope,
      "event_id" => stored.id,
      "kind" => stored.kind,
      "rule_id" => stored.rule_id,
      "generation" => Integer.to_string(stored.generation),
      "created_at" => stored.created_at,
      "event" => Codec.decode!(stored.document),
      "mode" => stored.mode,
      "physical_action_dispatch" => stored.action
    }

  defp receipt(stored, transition, disposition, event_disposition),
    do: %{
      "schema" => "wtr.rule-commit.v1",
      "outcome" => "committed",
      "disposition" => disposition,
      "scope" => transition.scope,
      "kind" => transition.kind,
      "rule_id" => transition.rule_id,
      "generation" => Integer.to_string(stored.generation),
      "state_identity" => stored.state_identity,
      "transition_identity" => stored.transition_identity,
      "event_id" => RuleTransition.event_identity(transition),
      "event_disposition" => event_disposition
    }

  defp event_receipt(generation, intent, disposition, event_disposition),
    do: %{
      "schema" => "wtr.rule-event-commit.v1",
      "outcome" => "committed",
      "disposition" => disposition,
      "scope" => intent.scope,
      "kind" => intent.kind,
      "rule_id" => intent.rule_id,
      "generation" => Integer.to_string(generation),
      "event_id" => RuleEvent.event_identity(intent),
      "event_disposition" => event_disposition
    }

  defp capacity!(_db, _table, 0, _maximum), do: :ok

  defp capacity!(db, table, count, maximum) do
    [[current]] = SQL.rows!(db, "SELECT count(*) FROM #{table}")
    if current + count > maximum, do: throw({:storage, :capacity_exceeded})
  end

  defp transaction(db, options, operation) do
    SQL.execute!(db, "BEGIN IMMEDIATE")

    result =
      try do
        result = operation.()
        fault!(options, :rule_before_commit)

        case SQL.boundary(fn -> SQL.execute!(db, "COMMIT") end) do
          :ok -> result
          {:error, _} -> throw({:storage, :unknown})
        end
      after
        SQL.rollback(db)
      end

    case options.fault.(:rule_after_commit) do
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
