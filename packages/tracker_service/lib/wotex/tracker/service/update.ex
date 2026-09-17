defmodule Wotex.Tracker.Service.Update do
  @moduledoc """
  A prepared host admission transaction, after authentication and domain checks.

  This is an internal host seam, never a wire format. The service prepares the
  records and public event projections; a client cannot supply arbitrary derived
  state. `request` contains the complete admitted caller intent used for scoped
  idempotency, excluding server-generated results. A nil record value is a
  historical tombstone. Nothing deletes evidence implicitly. Optional `rules` are
  revalidated rule transitions derived from the same admitted inputs; they commit
  at this update's generation or not at all.
  """

  alias Wotex.Tracker.Observation
  alias Wotex.Tracker.Service.{Access, Authority, Codec, RuleTransition}

  @kinds ~w(enrollments things state policies saved_queries evidence resolutions access)
  @keys ~w(principal scope operation_id expected_generation request now observation records events publication)a
  @enforce_keys @keys
  @optional [:authority, :response, :rules]
  defstruct @keys ++ [authority: nil, response: nil, rules: []]

  @type t :: %__MODULE__{
          principal: String.t(),
          scope: String.t(),
          operation_id: String.t(),
          expected_generation: String.t(),
          request: Wotex.JSON.json_value(),
          now: non_neg_integer(),
          observation: Observation.t() | nil,
          records: [map()],
          events: [map()],
          publication: map() | nil,
          authority: Access.t() | nil,
          response: map() | nil,
          rules: [RuleTransition.t()]
        }

  @doc "Admits one bounded transaction; derived records must already be authorized."
  @spec new(term()) :: {:ok, t()} | {:error, :invalid_update}
  def new(input) do
    with true <-
           is_map(input) and not is_struct(input) and
             map_size(input) in length(@keys)..(length(@keys) + length(@optional)) and
             Enum.sort(Map.keys(Map.drop(input, @optional))) == Enum.sort(@keys),
         true <- Authority.valid?(Map.get(input, :authority)),
         true <- response?(Map.get(input, :response)),
         true <- Enum.all?([input.principal, input.scope, input.operation_id], &Codec.id?/1),
         {:ok, _} <- Codec.generation(input.expected_generation),
         true <- Codec.time?(input.now),
         {:ok, _} <- Codec.encode(input.request),
         {:ok, observation} <- observation(input.observation),
         true <- bounded?(input.records, 16) and Enum.all?(input.records, &record?/1),
         true <- unique_records?(input.records),
         true <- bounded?(input.events, 16) and Enum.all?(input.events, &event?/1),
         true <- publication?(input.publication),
         true <- rules?(Map.get(input, :rules, []), input.scope),
         {:ok, _} <- Codec.encode(wire_size(input, observation)) do
      {:ok, struct!(__MODULE__, %{input | observation: observation})}
    else
      _ -> {:error, :invalid_update}
    end
  end

  @doc "Re-admits a prepared value, including manually constructed structs."
  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_update}
  def validate(%__MODULE__{} = update), do: new(Map.from_struct(update))
  def validate(_), do: {:error, :invalid_update}

  @doc "Lists the closed set of versioned domain record kinds."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  defp observation(nil), do: {:ok, nil}
  defp observation(value), do: Observation.validate(value)
  defp response?(nil), do: true
  defp response?(value), do: is_map(value) and match?({:ok, _}, Codec.encode(value, 16_384))
  defp bounded?([], _), do: true
  defp bounded?([_ | rest], count) when count > 0, do: bounded?(rest, count - 1)
  defp bounded?(_, _), do: false

  defp record?(%{kind: kind, id: id, value: value} = record) when map_size(record) == 3,
    do: kind in @kinds and Codec.id?(id) and match?({:ok, _}, Codec.encode(value, 262_144))

  defp record?(_), do: false

  defp event?(%{"type" => type, "data" => data} = event) when map_size(event) == 2,
    do:
      type in ~w(observation.admitted enrollment.changed thing.changed policy.changed query.changed tracker.event access.revoked) and
        is_map(data) and match?({:ok, _}, Codec.encode(event, 16_384))

  defp event?(_), do: false

  defp rules?(rules, scope) do
    bounded?(rules, 8) and
      Enum.all?(rules, &(match?({:ok, _}, RuleTransition.validate(&1)) and &1.scope == scope)) and
      length(Enum.uniq_by(rules, &{&1.kind, &1.rule_id})) == length(rules)
  end

  defp publication?(nil), do: true

  defp publication?(%{thing_id: id, deployment_id: revision, td: td} = publication)
       when map_size(publication) == 3 do
    Codec.id?(id) and Codec.id?(revision) and is_map(td) and
      match?({:ok, _}, Wotex.ThingDescription.from_map(td)) and Map.get(td, "id") == id
  end

  defp publication?(_), do: false

  defp unique_records?(records),
    do: length(Enum.uniq_by(records, &{&1.kind, &1.id})) == length(records)

  defp wire_size(input, observation) do
    document =
      if observation do
        {:ok, document} = Observation.to_map(observation)
        document
      end

    input
    |> Map.delete(:rules)
    |> Map.update(:authority, nil, &Authority.projection/1)
    |> Map.update!(:records, &Enum.map(&1, fn record -> stringify(record) end))
    |> Map.update!(:publication, fn value -> if value, do: stringify(value), else: nil end)
    |> Map.put(:observation, document)
    |> stringify()
  end

  defp stringify(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)
end
