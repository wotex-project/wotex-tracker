defmodule Wotex.Tracker.Service.SQL do
  @moduledoc false
  alias Exqlite.Sqlite3

  def execute!(db, sql), do: checked(Sqlite3.execute(db, sql))

  def rows!(db, sql, values \\ []) do
    statement = checked(Sqlite3.prepare(db, sql))

    try do
      checked(Sqlite3.bind(statement, values))
      checked(Sqlite3.fetch_all(db, statement))
    after
      Sqlite3.release(db, statement)
    end
  end

  def checked(:ok), do: :ok
  def checked({:ok, value}), do: value
  def checked({:error, reason}), do: throw({:storage, classify(reason)})

  def boundary(fun) do
    fun.()
  catch
    {:storage, code} -> {:error, code}
  end

  def rollback(db), do: Sqlite3.execute(db, "ROLLBACK")

  defp classify(reason) when reason in [:busy, "database is locked"], do: :busy
  defp classify("database or disk is full"), do: :storage_full
  defp classify(_), do: :storage_unavailable
end
