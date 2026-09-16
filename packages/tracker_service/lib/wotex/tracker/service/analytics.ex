defmodule Wotex.Tracker.Service.Analytics do
  @moduledoc false

  alias Wotex.Tracker.{Analytics, Error, QueryResult, QueryRow, QuerySpec}
  alias Wotex.Tracker.Service.{Codec, SQL, Transaction}

  @maximum_rows 100_000

  def query(db, scope, spec, authorize \\ fn -> :ok end, pinned_generation \\ nil) do
    with true <- Codec.id?(scope),
         {:ok, spec} <- QuerySpec.validate(spec),
         true <- is_nil(pinned_generation) or is_integer(pinned_generation) do
      SQL.execute!(db, "BEGIN")

      try do
        authorize.()
        current = Transaction.generation(db, scope)
        generation = pinned_generation || current
        if generation < 0 or generation > current, do: throw({:storage, :invalid_cursor})

        with {:ok, rows} <- rows(db, scope, generation, spec),
             {:ok, result} <-
               Analytics.evaluate(rows, spec, snapshot_identity(scope, generation)),
             {:ok, document} <- QueryResult.to_map(result) do
          {:ok, document}
        else
          {:error, %Error{code: :conflict}} -> {:error, :conflict}
          {:error, %Error{code: :limit_exceeded}} -> {:error, :capacity_exceeded}
          {:error, %Error{code: :invalid_json}} -> {:error, :response_too_large}
          {:error, %Error{}} -> {:error, :storage_unavailable}
          error -> error
        end
      after
        SQL.rollback(db)
      end
    else
      _ -> {:error, :invalid_query}
    end
  end

  defp rows(db, scope, generation, spec) do
    Enum.reduce_while(
      spec.series,
      {:ok, [], MapSet.new()},
      &add_series(db, scope, generation, spec, &1, &2)
    )
    |> then(fn
      {:ok, rows, _seen} -> {:ok, Enum.reverse(rows)}
      error -> error
    end)
  end

  defp add_series(db, scope, generation, spec, series, {:ok, rows, seen}) do
    remaining = @maximum_rows - length(rows)
    selected = measurement_rows(db, scope, series, generation, spec, remaining + 1)

    with true <- length(selected) <= remaining,
         {:ok, admitted, next_seen} <- admit_rows(selected, scope, series, spec, rows, seen) do
      {:cont, {:ok, admitted, next_seen}}
    else
      false -> {:halt, {:error, :capacity_exceeded}}
      error -> {:halt, error}
    end
  end

  defp measurement_rows(db, scope, series, generation, spec, limit) do
    SQL.rows!(
      db,
      """
      SELECT r.generation,
             json_extract(r.document,'$.public.observed_at.type'),
             json_extract(r.document,'$.public.observed_at.value'),
             json_extract(m.value,'$.value.type'),
             json_extract(m.value,'$.value.value'),
             json_extract(m.value,'$.unit'),
             json_extract(m.value,'$.availability'),
             json_extract(m.value,'$.quality')
      FROM records AS r
      JOIN json_each(r.document,'$.public.measurements') AS m
      WHERE r.scope=? AND r.kind='state' AND r.id=? AND r.generation<=?
        AND json_extract(r.document,'$.public.observed_at.type')='integer'
        AND json_extract(r.document,'$.public.observed_at.value')>=?
        AND json_extract(r.document,'$.public.observed_at.value')<?
        AND json_extract(m.value,'$.kind')=?
      ORDER BY json_extract(r.document,'$.public.observed_at.value'),r.generation
      LIMIT ?
      """,
      [
        scope,
        series,
        generation,
        spec.from_at,
        spec.to_at,
        spec.measurement,
        limit
      ]
    )
  end

  defp admit_rows(selected, scope, series, spec, rows, seen) do
    Enum.reduce_while(
      selected,
      {:ok, rows, seen},
      &admit_row(scope, series, spec.measurement, &1, &2)
    )
  end

  defp admit_row(scope, series, measurement, values, {:ok, rows, seen}) do
    key = {series, hd(values)}

    with false <- MapSet.member?(seen, key),
         {:ok, admitted} <- row(values, scope, series, measurement) do
      {:cont, {:ok, [admitted | rows], MapSet.put(seen, key)}}
    else
      true -> {:halt, {:error, :storage_unavailable}}
      error -> {:halt, error}
    end
  end

  defp row(
         [generation, "integer", event_at, value_type, value, unit, availability, quality],
         scope,
         series,
         measurement
       ) do
    with {:ok, availability} <- availability(availability, value_type, value),
         {:ok, quality} <- quality(quality),
         identity_input = %{
           "schema" => "wtr.service-measurement-row.v1",
           "scope" => scope,
           "series" => series,
           "record_generation" => Integer.to_string(generation),
           "measurement" => measurement,
           "event_at" => event_at,
           "value_type" => value_type,
           "value" => value,
           "unit" => unit,
           "availability" => Atom.to_string(availability),
           "quality" => Atom.to_string(quality)
         },
         {:ok, row} <-
           QueryRow.new(%{
             measurement: measurement,
             series: series,
             event_at: event_at,
             value: value,
             unit: unit,
             availability: availability,
             quality: quality,
             evidence_identity: evidence_identity(identity_input)
           }) do
      {:ok, row}
    else
      _ -> {:error, :storage_unavailable}
    end
  end

  defp row(_, _, _, _), do: {:error, :storage_unavailable}

  defp availability("available", type, value)
       when type in ["integer", "number"] and is_number(value),
       do: {:ok, :available}

  defp availability("unavailable", "null", nil), do: {:ok, :unavailable}
  defp availability(_, _, _), do: {:error, :storage_unavailable}

  defp quality("valid"), do: {:ok, :valid}
  defp quality("suspect"), do: {:ok, :suspect}
  defp quality("invalid"), do: {:ok, :invalid}
  defp quality(_), do: {:error, :storage_unavailable}

  defp evidence_identity(input),
    do: "wtr-service-row-v1:sha256:" <> Codec.digest(input)

  defp snapshot_identity(scope, generation) do
    digest =
      Codec.digest(%{
        "schema" => "wtr.service-snapshot.v1",
        "scope" => scope,
        "generation" => Integer.to_string(generation)
      })

    "wtr-service-snapshot-v1:sha256:" <> digest
  end
end
