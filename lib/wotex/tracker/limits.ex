defmodule Wotex.Tracker.Limits do
  @moduledoc "Explicit first-slice budgets. Unknown, repeated or invalid options are rejected."
  alias Wotex.Tracker.Error

  @defaults [
    max_bytes: 65_536,
    max_depth: 16,
    max_nodes: 4096,
    max_string_bytes: 4096,
    max_collection_size: 256,
    max_payload_bytes: 65_536,
    max_id_bytes: 256,
    max_claims: 256,
    max_sources: 64,
    max_lineage_depth: 16
  ]
  @json_keys ~w(max_bytes max_depth max_nodes max_string_bytes max_collection_size)a
  @type t :: %__MODULE__{}
  defstruct @defaults

  @doc "Admits a finite keyword list of positive integer budgets."
  @spec new(term()) :: {:ok, t()} | {:error, Error.t()}
  def new(options \\ []), do: admit(options, %__MODULE__{}, [])

  @doc "Projects admitted JSON budgets to upstream options."
  @spec json(t()) :: keyword(pos_integer())
  def json(%__MODULE__{} = limits), do: Enum.map(@json_keys, &{&1, Map.fetch!(limits, &1)})

  defp admit([], limits, _seen), do: {:ok, limits}

  defp admit([{key, value} | rest], limits, seen) when is_atom(key) do
    cond do
      key not in Keyword.keys(@defaults) or key in seen ->
        {:error, Error.new(:invalid_options, :admission)}

      not is_integer(value) or value <= 0 ->
        {:error, Error.new(:invalid_limit, :admission)}

      true ->
        admit(rest, Map.put(limits, key, value), [key | seen])
    end
  end

  defp admit(_, _, _), do: {:error, Error.new(:invalid_options, :admission)}
end
