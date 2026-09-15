defmodule Wotex.Tracker.Service.Result do
  @moduledoc false
  alias Wotex.Tracker.Service.Identifier

  @codes ~w(unauthorized forbidden invalid_request invalid_observation invalid_cursor cursor_expired operation_expired not_found conflict idempotency_conflict observation_conflict unsupported unresolved revision_mismatch invalid_deployment invalid_materialisation storage_unavailable storage_full busy capacity_exceeded response_too_large overloaded invalid_query invalid_update)a

  def error(code, path \\ "/") when code in @codes,
    do: {:error, %{"code" => Atom.to_string(code), "path" => path}}

  def normalize({:ok, value}), do: {:ok, value}

  def normalize({:error, code}) when code in [:unknown, :injected_failure],
    do: error(:storage_unavailable)

  def normalize({:error, code}) when code in @codes, do: error(code)

  def normalize({:error, %{"code" => _code, "path" => _path} = error}) when map_size(error) == 2,
    do: {:error, error}

  def mutation({:ok, value}, _id), do: {:ok, value}
  def mutation({:error, :unknown}, id), do: {:ok, %{"outcome" => "unknown", "operation_id" => id}}

  def mutation({:error, error}, id) do
    {:error, error} = normalize({:error, error})

    {:error,
     Map.merge(error, %{
       "outcome" => "not_committed",
       "operation_id" => if(Identifier.operation?(id), do: id, else: nil)
     })}
  end
end
