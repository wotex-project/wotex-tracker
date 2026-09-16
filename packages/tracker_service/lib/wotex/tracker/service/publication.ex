defmodule Wotex.Tracker.Service.Publication do
  @moduledoc false

  alias Wotex.Tracker.Service.{Codec, SQL}

  def status(db, scope, thing, generation) do
    with true <- Codec.id?(scope) and Codec.id?(thing),
         {:ok, version} <- Codec.generation(generation) do
      lookup(db, scope, thing, version)
    else
      _ -> {:error, :invalid_query}
    end
  end

  def latest(db, scope, thing) do
    if Codec.id?(scope) and Codec.id?(thing) do
      case SQL.rows!(
             db,
             "SELECT max(generation) FROM publications WHERE scope=? AND thing_id=?",
             [scope, thing]
           ) do
        [[nil]] -> {:error, :not_found}
        [[version]] -> lookup(db, scope, thing, version)
      end
    else
      {:error, :invalid_query}
    end
  end

  def confirm(db, scope, thing, generation, cleanup) do
    with true <- cleanup in ~w(pending complete failed),
         {:ok, _} <- status(db, scope, thing, generation) do
      SQL.execute!(db, "BEGIN IMMEDIATE")

      try do
        {:ok, current} = latest(db, scope, thing)
        if current["generation"] != generation, do: throw({:storage, :superseded})
        cleanup = cleanup_status(current["cleanup"], cleanup)

        SQL.rows!(
          db,
          "UPDATE publications SET status='published',cleanup=? WHERE scope=? AND thing_id=? AND generation=?",
          [cleanup, scope, thing, generation]
        )

        SQL.execute!(db, "COMMIT")
        status(db, scope, thing, generation)
      after
        SQL.rollback(db)
      end
    else
      false -> {:error, :invalid_query}
      error -> error
    end
  end

  defp cleanup_status("complete", _), do: "complete"
  defp cleanup_status("failed", "pending"), do: "failed"
  defp cleanup_status(_, next), do: next

  defp lookup(db, scope, thing, version) do
    case SQL.rows!(
           db,
           "SELECT operation_id,document,status,cleanup FROM publications WHERE scope=? AND thing_id=? AND generation=?",
           [scope, thing, version]
         ) do
      [[operation, document, status, cleanup]] ->
        {:ok,
         %{
           "thing_id" => thing,
           "generation" => Integer.to_string(version),
           "operation_id" => operation,
           "document" => Codec.decode!(document),
           "status" => status,
           "cleanup" => cleanup
         }}

      [] ->
        {:error, :not_found}
    end
  end
end
