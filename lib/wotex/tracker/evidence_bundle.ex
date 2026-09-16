defmodule Wotex.Tracker.EvidenceBundle do
  @moduledoc """
  A closed immutable observation/claim snapshot. Conflicting IDs, dangling or
  cyclic references, mixed revisions and mixed device associations are rejected.

  Equal duplicate observations or claims are idempotent only under `===`.
  Bundle identity covers full capture facts and claims, including units, quality,
  association and revisions. Expired evidence needs an explicit future retained
  record adapter; this closed first-slice bundle never pretends bytes are retained.
  """
  alias Wotex.Tracker.{Admission, Error, Evidence, Limits, Observation}

  @type t :: %__MODULE__{observations: map(), evidence: map(), identity: String.t()}
  @enforce_keys [:observations, :evidence, :identity]
  defstruct [:observations, :evidence, :identity]

  @doc "Admits a closed bounded bundle and calculates its full content identity."
  @spec new(term(), term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(observations, evidence, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         :ok <- Admission.bounded_list(observations, limits.max_claims),
         :ok <- Admission.bounded_list(evidence, limits.max_claims),
         {:ok, observations} <- index(observations, &Observation.validate(&1, options)),
         {:ok, evidence} <- index(evidence, &Evidence.validate(&1, options)),
         :ok <- consistent(evidence),
         :ok <- references(observations, evidence, limits),
         {:ok, identity} <- digest(observations, evidence, options, limits) do
      {:ok, %__MODULE__{observations: observations, evidence: evidence, identity: identity}}
    end
  end

  @doc "Revalidates contents and rejects a forged or stale bundle identity."
  @spec validate(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(value, options \\ [])

  def validate(
        %__MODULE__{observations: observations, evidence: evidence, identity: identity},
        options
      )
      when is_map(observations) and is_map(evidence) do
    with {:ok, limits} <- Limits.new(options),
         true <-
           map_size(observations) <= limits.max_claims and map_size(evidence) <= limits.max_claims,
         true <-
           Enum.all?(observations, fn {id, value} ->
             is_struct(value, Observation) and id === Map.get(value, :id)
           end),
         true <-
           Enum.all?(evidence, fn {id, value} ->
             is_struct(value, Evidence) and id === Map.get(value, :id)
           end),
         {:ok, bundle} <- new(Map.values(observations), Map.values(evidence), options),
         true <- bundle.identity === identity do
      {:ok, bundle}
    else
      false -> Admission.fail(:conflict)
      error -> error
    end
  end

  def validate(_, _), do: Admission.fail(:invalid_input)

  @doc "Projects a validated bundle with complete observations and evidence to native JSON."
  @spec to_map(term(), term()) :: {:ok, map()} | {:error, Error.t()}
  def to_map(value, options \\ []) do
    with {:ok, bundle} <- validate(value, options),
         {:ok, observations} <- documents(bundle.observations, &Observation.to_map(&1, options)),
         {:ok, evidence} <- documents(bundle.evidence, &Evidence.to_map(&1, options)) do
      {:ok,
       %{
         "schema" => "wtr.evidence-bundle.v1",
         "observations" => observations,
         "evidence" => evidence,
         "identity" => bundle.identity
       }}
    end
  end

  @doc "Restores and revalidates a complete native-JSON evidence bundle."
  @spec from_map(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(document, options \\ []) do
    with true <-
           is_map(document) and not is_struct(document) and
             Enum.sort(Map.keys(document)) == ~w(evidence identity observations schema),
         true <- document["schema"] == "wtr.evidence-bundle.v1",
         {:ok, observations} <-
           restore_documents(document["observations"], &Observation.from_map(&1, options)),
         {:ok, evidence} <-
           restore_documents(document["evidence"], &Evidence.from_map(&1, options)),
         {:ok, bundle} <- new(observations, evidence, options),
         true <- bundle.identity == document["identity"] do
      {:ok, bundle}
    else
      false -> Admission.fail(:conflict)
      error -> error
    end
  end

  defp documents(values, serialize) do
    values
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn {_id, value}, {:ok, documents} ->
      case serialize.(value) do
        {:ok, document} -> {:cont, {:ok, [document | documents]}}
        error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, documents} -> {:ok, Enum.reverse(documents)}
      error -> error
    end)
  end

  defp restore_documents(values, restore) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn document, {:ok, restored} ->
      case restore.(document) do
        {:ok, value} -> {:cont, {:ok, [value | restored]}}
        error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, restored} -> {:ok, Enum.reverse(restored)}
      error -> error
    end)
  end

  defp restore_documents(_, _), do: Admission.fail(:invalid_input)

  defp index(values, validate) do
    Enum.reduce_while(values, {:ok, %{}}, fn value, {:ok, acc} ->
      with {:ok, value} <- validate.(value),
           :ok <- insertable(acc, value) do
        {:cont, {:ok, Map.put(acc, value.id, value)}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp insertable(acc, value) do
    case Map.fetch(acc, value.id) do
      {:ok, previous} when previous !== value -> Admission.fail(:conflict)
      _ -> :ok
    end
  end

  defp consistent(evidence) do
    revisions = evidence |> Map.values() |> Enum.map(&{&1.profile, &1.decoder}) |> Enum.uniq()

    associations =
      evidence
      |> Map.values()
      |> Enum.map(& &1.association_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    cond do
      length(revisions) > 1 -> Admission.fail(:revision_mismatch)
      length(associations) > 1 -> Admission.fail(:association_mismatch)
      true -> :ok
    end
  end

  defp references(observations, evidence, limits) do
    with :ok <-
           Admission.each(Map.values(evidence), &source_refs(&1, observations)) do
      lineage(evidence, limits)
    end
  end

  defp source_refs(claim, observations) do
    if Enum.all?(claim.source_observation_ids, &Map.has_key?(observations, &1)),
      do: :ok,
      else: Admission.fail(:dangling_reference)
  end

  defp lineage(evidence, limits) do
    evidence
    |> Map.keys()
    |> Enum.reduce_while({:ok, %{}, 0}, fn id, {:ok, memo, _} ->
      case visit(id, evidence, [], limits.max_lineage_depth, memo) do
        {:ok, _, _} = result -> {:cont, result}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _, _} -> :ok
      error -> error
    end
  end

  defp visit(id, evidence, ancestors, remaining, memo) do
    cond do
      id in ancestors ->
        Admission.fail(:evidence_cycle)

      remaining == 0 ->
        Admission.fail(:limit_exceeded)

      not Map.has_key?(evidence, id) ->
        Admission.fail(:dangling_reference)

      Map.has_key?(memo, id) ->
        if memo[id] <= remaining, do: {:ok, memo, memo[id]}, else: Admission.fail(:limit_exceeded)

      true ->
        visit_parents(id, evidence, ancestors, remaining, memo)
    end
  end

  defp visit_parents(id, evidence, ancestors, remaining, memo) do
    result =
      Enum.reduce_while(evidence[id].evidence_ids, {:ok, memo, 0}, fn parent,
                                                                      {:ok, memo, longest} ->
        case visit(parent, evidence, [id | ancestors], remaining - 1, memo) do
          {:ok, memo, depth} -> {:cont, {:ok, memo, max(longest, depth)}}
          error -> {:halt, error}
        end
      end)

    case result do
      {:ok, memo, longest} -> {:ok, Map.put(memo, id, longest + 1), longest + 1}
      error -> error
    end
  end

  defp digest(observations, evidence, options, limits) do
    claims =
      evidence
      |> Enum.sort()
      |> Enum.map(fn {_id, claim} ->
        {:ok, map} = Evidence.to_map(claim, options)
        map
      end)

    with :ok <- Admission.json(claims, limits),
         {:ok, captures} <- observation_identities(observations, options) do
      # Each capture digest covers its entire separately admitted observation.
      Admission.digest(
        %{"schema" => "wtr.bundle.v1", "observations" => captures, "evidence" => claims},
        Limits.json(limits)
        |> Keyword.put(:max_bytes, limits.max_bytes + 131_072)
        |> Keyword.put(:max_nodes, limits.max_nodes + 1024)
        |> Keyword.put(:max_depth, limits.max_depth + 2)
      )
    end
  end

  defp observation_identities(observations, options) do
    Enum.reduce_while(Enum.sort(observations), {:ok, []}, fn {id, observation}, {:ok, acc} ->
      case Observation.identity(observation, options) do
        {:ok, digest} -> {:cont, {:ok, [%{"id" => id, "identity" => digest} | acc]}}
        error -> {:halt, error}
      end
    end)
  end
end
