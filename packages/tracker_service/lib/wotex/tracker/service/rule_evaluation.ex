defmodule Wotex.Tracker.Service.RuleEvaluation do
  @moduledoc false

  # Evaluates a Thing's heartbeat and battery definitions against one complete
  # receiver observation and evidence bundle. Only changed live results become
  # transitions; the caller stages them in the same update transaction.

  alias Wotex.Tracker.{
    BatteryTransition,
    Evidence,
    EvidenceBundle,
    HeartbeatTransition,
    MeasurementSample,
    Observation
  }

  alias Wotex.Tracker.Service.{RuleDefinition, RuleTransition, Snapshot, Store}

  def definitions(service, access, permission, thing, generation, now) do
    with {:ok, %{"items" => rows}} <-
           Store.authorized_policies(service.store, access, permission, thing, generation, now),
         do: decode(rows, [])
  end

  defp decode([], definitions), do: {:ok, Enum.reverse(definitions)}

  defp decode([row | rows], definitions) do
    with {:ok, definition} <- RuleDefinition.definition(row["value"], row["id"]),
         do: decode(rows, [definition | definitions])
  end

  # Loads the evidence committed by the Thing's latest materialisation.
  def committed_input(service, access, permission, thing, generation, now) do
    with {:ok, row} <-
           Snapshot.fetch(service, access, "evidence", thing, generation, permission, now),
         {:ok, evidence} <- restore_evidence(row["value"]["claims"]),
         [observation_id] <- source_observations(evidence),
         {:ok, stored} <-
           Snapshot.fetch(
             service,
             access,
             "observations",
             observation_id,
             generation,
             permission,
             now
           ),
         {:ok, observation} <- Observation.from_map(stored["value"]),
         {:ok, bundle} <- EvidenceBundle.new([observation], evidence) do
      {:ok, observation, bundle}
    else
      {:error, code} when is_atom(code) -> {:error, code}
      _ -> {:error, :storage_unavailable}
    end
  end

  def transitions(service, scope, definitions, observation, bundle, now) do
    Enum.reduce_while(definitions, {:ok, []}, fn definition, {:ok, transitions} ->
      case transition(service, scope, definition, observation, bundle, now) do
        {:ok, nil} -> {:cont, {:ok, transitions}}
        {:ok, transition} -> {:cont, {:ok, [transition | transitions]}}
        error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, transitions} -> {:ok, Enum.reverse(transitions)}
      error -> error
    end)
  end

  defp transition(service, scope, definition, observation, bundle, now) do
    with {:ok, previous} <- previous(service, scope, definition),
         {:ok, result} <- evaluate(definition, previous, observation, bundle, now) do
      changed(scope, previous, result)
    end
  end

  defp previous(service, scope, %{kind: kind, policy: policy}) do
    case Store.rule_state(service.store, scope, kind, policy.id) do
      {:ok, %{"state" => document}} -> restore(kind, document)
      {:error, :not_found} -> {:ok, nil}
      _ -> {:error, :storage_unavailable}
    end
  end

  defp restore("heartbeat", document), do: stored(HeartbeatTransition.state_from_map(document))
  defp restore("battery", document), do: stored(BatteryTransition.state_from_map(document))

  defp stored({:ok, state}), do: {:ok, state}
  defp stored(_), do: {:error, :storage_unavailable}

  defp evaluate(%{kind: "heartbeat", policy: policy}, previous, observation, _bundle, now),
    do: result(HeartbeatTransition.evaluate(previous, observation, policy, :live, now))

  defp evaluate(%{kind: "battery", policy: policy}, previous, _observation, bundle, now) do
    case sample(bundle, policy) do
      {:ok, sample} -> result(BatteryTransition.evaluate(previous, sample, policy, :live, now))
      :none -> {:ok, nil}
      error -> result(error)
    end
  end

  defp result({:ok, result}), do: {:ok, result}
  defp result(_), do: {:error, :conflict}

  defp changed(_scope, _previous, nil), do: {:ok, nil}
  defp changed(_scope, _previous, %{"state_changed" => false}), do: {:ok, nil}

  # The pure evaluator just produced this result, so its transition is always admissible.
  defp changed(scope, previous, result), do: RuleTransition.new(scope, previous, result)

  # A Thing without the declared measurement in this evidence leaves the rule unchanged.
  defp sample(bundle, policy) do
    bundle.evidence
    |> Map.values()
    |> Enum.filter(fn evidence ->
      evidence.kind == :measurement and evidence.claim["kind"] == policy.measurement_kind and
        evidence.claim["unit"] == policy.unit
    end)
    |> Enum.sort_by(& &1.id)
    |> case do
      [evidence | _] ->
        MeasurementSample.new(evidence.id, bundle)

      [] ->
        :none
    end
  end

  defp restore_evidence(claims) when is_list(claims) do
    Enum.reduce_while(claims, {:ok, []}, fn claim, {:ok, evidence} ->
      case Evidence.from_map(claim) do
        {:ok, value} -> {:cont, {:ok, [value | evidence]}}
        _ -> {:halt, {:error, :storage_unavailable}}
      end
    end)
  end

  defp restore_evidence(_), do: {:error, :storage_unavailable}

  defp source_observations(evidence),
    do: evidence |> Enum.flat_map(& &1.source_observation_ids) |> Enum.uniq()
end
