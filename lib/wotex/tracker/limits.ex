defmodule Wotex.Tracker.Limits do
  @moduledoc """
  Admits resource budgets shared by Tracker's pure constructors.

  `new/1` starts from finite defaults and accepts positive integer overrides in
  a keyword list. Unknown, repeated, and invalid options fail admission.
  `json/1` projects the normal JSON limits; `material/1` supplies the separate
  larger budget for Thing materialisation. Callers can lower or raise a budget
  explicitly without changing the shape of the admitted data.
  """

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
    max_lineage_depth: 16,
    max_profiles: 256,
    max_predicates: 32,
    max_candidates: 256,
    max_affordances: 64,
    max_forms: 8,
    max_material_bytes: 262_144,
    max_material_depth: 32,
    max_material_nodes: 16_384
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

  @doc "Projects the separate materialisation budgets to upstream JSON options."
  @spec material(t()) :: keyword(pos_integer())
  def material(%__MODULE__{} = limits) do
    [
      max_bytes: limits.max_material_bytes,
      max_depth: limits.max_material_depth,
      max_nodes: limits.max_material_nodes,
      max_string_bytes: limits.max_material_bytes,
      max_collection_size: max(256, limits.max_affordances)
    ]
  end

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
