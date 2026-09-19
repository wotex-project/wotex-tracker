defmodule Wotex.Tracker.Service.TripSummaryInput do
  @moduledoc false

  alias Wotex.Tracker.Service.{Codec, SQL, Transaction}

  @maximum_samples 100

  def read(db, scope, thing, trip, authorize) do
    case Enum.all?([scope, thing, trip], &Codec.id?/1) do
      true -> snapshot(db, scope, thing, trip, authorize)
      false -> {:error, :invalid_query}
    end
  end

  defp snapshot(db, scope, thing, trip, authorize) do
    SQL.execute!(db, "BEGIN")

    try do
      authorize.()
      generation = Transaction.generation(db, scope)

      with {:ok, started, terminal} <- events(db, scope, trip, generation),
           true <- bound?(db, scope, thing, started),
           {:ok, state} <- start_state(db, scope, started),
           {:ok, first_generation} <- start_generation(db, scope, thing, started, terminal),
           {:ok, inputs} <- inputs(db, scope, thing, first_generation, terminal.generation) do
        {:ok,
         %{
           "generation" => Integer.to_string(terminal.generation),
           "started" => started.event,
           "terminal" => terminal.event,
           "terminal_created_at" => terminal.created_at,
           "start_state" => state,
           "inputs" => inputs
         }}
      else
        false -> {:error, :not_found}
        error -> error
      end
    after
      SQL.rollback(db)
    end
  end

  defp events(db, scope, trip, generation) do
    rows =
      SQL.rows!(
        db,
        "SELECT rule_id,generation,created_at,document FROM rule_event_intents " <>
          "WHERE scope=? AND kind='motion' AND generation<=? " <>
          "AND json_extract(document,'$.trip_id')=? ORDER BY generation",
        [scope, generation, trip]
      )

    events =
      Enum.map(rows, fn [rule_id, event_generation, created_at, document] ->
        %{
          rule_id: rule_id,
          generation: event_generation,
          created_at: created_at,
          event: Codec.decode!(document)
        }
      end)

    started = Enum.filter(events, &(&1.event["kind"] == "trip.started"))
    terminal = Enum.filter(events, &(&1.event["kind"] in ~w(trip.stopped trip.interrupted)))

    case {started, terminal} do
      {[started], [terminal]}
      when started.rule_id == terminal.rule_id and started.generation < terminal.generation ->
        {:ok, started, terminal}

      {[], _} ->
        {:error, :not_found}

      {[_], []} ->
        {:error, :not_found}

      _ ->
        {:error, :storage_unavailable}
    end
  end

  defp bound?(db, scope, thing, started) do
    SQL.rows!(
      db,
      "SELECT 1 FROM records WHERE scope=? AND kind='policies' AND id=? " <>
        "AND generation<=? AND document!='null' " <>
        "AND json_extract(document,'$.public.kind')='motion' " <>
        "AND json_extract(document,'$.public.thing_id')=? LIMIT 1",
      [scope, started.rule_id, started.generation, thing]
    ) == [[1]]
  end

  defp start_state(db, scope, started) do
    case SQL.rows!(
           db,
           "SELECT document FROM records WHERE scope=? AND kind='rules' AND id=? " <>
             "AND generation=? LIMIT 1",
           [scope, "motion:" <> started.rule_id, started.generation]
         ) do
      [[document]] -> {:ok, Codec.decode!(document)}
      _ -> {:error, :storage_unavailable}
    end
  end

  defp start_generation(db, scope, thing, started, terminal) do
    evidence = started.event["from_position_evidence_id"]

    case SQL.rows!(
           db,
           "SELECT r.generation FROM records r WHERE r.scope=? AND r.kind='evidence' " <>
             "AND r.id=? AND r.generation<=? AND EXISTS (" <>
             "SELECT 1 FROM json_each(r.document,'$.claims') c " <>
             "WHERE json_extract(c.value,'$.id')=?) ORDER BY r.generation DESC LIMIT 1",
           [scope, thing, terminal.generation, evidence]
         ) do
      [[generation]] -> {:ok, generation}
      _ -> {:error, :storage_unavailable}
    end
  end

  defp inputs(db, scope, thing, first_generation, terminal_generation) do
    rows =
      SQL.rows!(
        db,
        "SELECT generation,document FROM records WHERE scope=? AND kind='evidence' AND id=? " <>
          "AND generation>=? AND generation<=? ORDER BY generation LIMIT ?",
        [scope, thing, first_generation, terminal_generation, @maximum_samples + 1]
      )

    if length(rows) > @maximum_samples do
      {:error, :capacity_exceeded}
    else
      collect_inputs(db, scope, rows, terminal_generation)
    end
  end

  defp collect_inputs(db, scope, rows, terminal_generation) do
    Enum.reduce_while(rows, {:ok, []}, fn [generation, document], {:ok, inputs} ->
      evidence = Codec.decode!(document)

      case observation(db, scope, evidence, terminal_generation) do
        {:ok, observation} ->
          input = %{
            "generation" => Integer.to_string(generation),
            "evidence" => evidence,
            "observation" => observation
          }

          {:cont, {:ok, [input | inputs]}}

        error ->
          {:halt, error}
      end
    end)
    |> then(fn
      {:ok, inputs} -> {:ok, Enum.reverse(inputs)}
      error -> error
    end)
  end

  defp observation(db, scope, %{"claims" => claims}, generation) when is_list(claims) do
    ids =
      claims
      |> Enum.flat_map(fn
        %{"source_observation_ids" => ids} when is_list(ids) -> ids
        _ -> []
      end)
      |> Enum.uniq()

    case ids do
      [id] when is_binary(id) -> observation_row(db, scope, id, generation)
      _ -> {:error, :storage_unavailable}
    end
  end

  defp observation(_, _, _, _), do: {:error, :storage_unavailable}

  defp observation_row(db, scope, id, generation) do
    case SQL.rows!(
           db,
           "SELECT document FROM observations WHERE scope=? AND id=? AND generation<=? LIMIT 1",
           [scope, id, generation]
         ) do
      [[document]] -> {:ok, Codec.decode!(document)}
      _ -> {:error, :storage_unavailable}
    end
  end
end
