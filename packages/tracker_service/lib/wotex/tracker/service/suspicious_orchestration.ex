defmodule Wotex.Tracker.Service.SuspiciousOrchestration do
  @moduledoc false

  # Event-only suspicious movement is evaluated from the exact live definition,
  # motion state and evidence facts visible to the triggering mutation. Staged
  # inputs win over the committed snapshot so the resulting intent shares the
  # mutation's atomic boundary.

  alias Wotex.Tracker.{MotionTransition, SuspiciousMovement}

  alias Wotex.Tracker.Service.{
    Arming,
    OwnerPresence,
    RuleDefinition,
    RuleEvaluation,
    RuleEvent,
    Store,
    Update
  }

  @spec attach(map(), struct(), String.t(), String.t(), Update.t()) ::
          {:ok, Update.t()} | {:error, atom()}
  def attach(service, access, permission, thing, %Update{} = update) do
    with {:ok, definitions} <- definitions(service, access, permission, thing, update),
         {:ok, intents} <- intents(service, access, permission, thing, update, definitions) do
      update
      |> Map.from_struct()
      |> Map.put(:rule_events, update.rule_events ++ intents)
      |> Update.new()
    end
  end

  defp definitions(service, access, permission, thing, update) do
    with {:ok, definitions} <-
           RuleEvaluation.definitions(
             service,
             access,
             permission,
             thing,
             update.expected_generation,
             update.now
           ),
         do: staged_definitions(definitions, update.records, thing)
  end

  defp staged_definitions(definitions, records, thing) do
    Enum.reduce_while(records, {:ok, definitions}, fn
      %{kind: "policies", id: id, value: nil}, {:ok, current} ->
        {:cont, {:ok, Enum.reject(current, &(definition_id(&1) == id))}}

      %{kind: "policies", id: id, value: value}, {:ok, current} ->
        case RuleDefinition.definition(value, id) do
          {:ok, %{thing_id: ^thing} = definition} ->
            retained = Enum.reject(current, &(definition_id(&1) == id))
            {:cont, {:ok, [definition | retained]}}

          _ ->
            {:halt, {:error, :storage_unavailable}}
        end

      _record, result ->
        {:cont, result}
    end)
  end

  defp intents(service, access, permission, thing, update, definitions) do
    definitions
    |> Enum.filter(&(&1.kind == "suspicious_movement"))
    |> Enum.reduce_while({:ok, []}, fn definition, {:ok, intents} ->
      case intent(service, access, permission, thing, update, definitions, definition) do
        {:ok, nil} -> {:cont, {:ok, intents}}
        {:ok, intent} -> {:cont, {:ok, [intent | intents]}}
        error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, intents} -> {:ok, Enum.reverse(intents)}
      error -> error
    end)
  end

  defp intent(service, access, permission, thing, update, definitions, suspicious) do
    with {:ok, motion_definition} <- matching_motion(definitions, suspicious),
         {:ok, motion_state} <- motion_state(service, update, motion_definition),
         {:ok, armed} <-
           fact(service, access, permission, thing, update, "arming", &Arming.restore_fact/2),
         {:ok, owner} <-
           fact(
             service,
             access,
             permission,
             thing,
             update,
             "owner_presence",
             &OwnerPresence.restore_fact/2
           ) do
      evaluate(update.scope, motion_state, armed, owner, suspicious.policy, update.now)
    else
      :missing -> {:ok, nil}
      :mismatch -> {:ok, nil}
      error -> error
    end
  end

  defp matching_motion(definitions, suspicious) do
    case Enum.find(definitions, fn definition ->
           definition.kind == "motion" and definition.policy.id == suspicious.motion_rule_id
         end) do
      %{policy: policy} = definition
      when policy.identity == suspicious.policy.motion_policy.identity ->
        {:ok, definition}

      nil ->
        :missing

      _changed ->
        :mismatch
    end
  end

  defp motion_state(service, update, motion_definition) do
    staged =
      Enum.find(update.rules, fn transition ->
        transition.kind == "motion" and transition.rule_id == motion_definition.policy.id
      end)

    case staged do
      nil -> committed_motion_state(service, update.scope, motion_definition)
      transition -> restore_motion_state(transition.document, motion_definition)
    end
  end

  defp committed_motion_state(service, scope, motion_definition) do
    case Store.rule_state(service.store, scope, "motion", motion_definition.policy.id) do
      {:ok, %{"state" => document}} -> restore_motion_state(document, motion_definition)
      {:error, :not_found} -> :missing
      _ -> {:error, :storage_unavailable}
    end
  end

  defp restore_motion_state(document, motion_definition) do
    with {:ok, state} <- MotionTransition.state_from_map(document),
         true <- state.policy.identity == motion_definition.policy.identity do
      {:ok, state}
    else
      false -> :mismatch
      _ -> {:error, :storage_unavailable}
    end
  end

  defp fact(service, access, permission, thing, update, kind, restore) do
    case Enum.find(update.records, &(&1.kind == kind and &1.id == thing)) do
      %{value: value} ->
        restore_fact(restore, thing, value)

      nil ->
        committed_fact(service, access, permission, thing, update, kind, restore)
    end
  end

  defp committed_fact(service, access, permission, thing, update, kind, restore) do
    query = %{
      scope: update.scope,
      kind: kind,
      id: thing,
      generation: update.expected_generation
    }

    case Store.authorized_fetch(service.store, access, permission, query, update.now) do
      {:ok, %{"value" => value}} -> restore_fact(restore, thing, value)
      {:error, :not_found} -> :missing
      error -> error
    end
  end

  defp restore_fact(restore, thing, value) do
    case restore.(thing, value) do
      {:ok, fact} -> {:ok, fact}
      _ -> {:error, :storage_unavailable}
    end
  end

  defp evaluate(scope, motion_state, armed, owner, policy, now) do
    case SuspiciousMovement.evaluate(motion_state, armed, owner, policy, :live, now) do
      {:ok, %{"event" => nil}} ->
        {:ok, nil}

      {:ok, result} ->
        scope
        |> RuleEvent.suspicious_movement(motion_state, armed, owner, policy, result)
        |> admitted_intent()

      _ ->
        {:error, :storage_unavailable}
    end
  end

  defp admitted_intent({:ok, intent}), do: {:ok, intent}
  defp admitted_intent(_), do: {:error, :storage_unavailable}

  defp definition_id(%{policy: policy}), do: policy.id
end
