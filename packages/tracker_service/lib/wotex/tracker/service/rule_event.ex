defmodule Wotex.Tracker.Service.RuleEvent do
  @moduledoc """
  A re-evaluated event-only rule result prepared for atomic host deduplication.

  Complete closed inputs remain attached to the prepared value so validation can
  restore and re-run the pure rule before the store records its stable event.
  """

  alias Wotex.Tracker.{
    Geofence,
    GeofenceCrossing,
    MotionTransition,
    PolicyFact,
    PositionSample,
    SuspiciousMovement
  }

  alias Wotex.Tracker.Service.Codec

  @crossing_kind "geofence_crossing"
  @suspicious_kind "suspicious_movement"
  @crossing_input_fields ~w(schema fence from to policy)
  @suspicious_input_fields ~w(schema motion_state armed owner_presence policy)
  @fields [
    :scope,
    :kind,
    :rule_id,
    :inputs,
    :result,
    :event,
    :mode,
    :action,
    :evaluated_at,
    :identity
  ]
  @enforce_keys @fields
  defstruct @fields
  @type t :: %__MODULE__{}

  @doc "Restores and re-evaluates an inferred crossing before preparing its event intent."
  @spec geofence_crossing(String.t(), term(), term(), term(), term(), map()) ::
          {:ok, t()} | {:error, :invalid_rule_event}
  def geofence_crossing(scope, fence, from, to, policy, result) do
    with true <- Codec.id?(scope),
         {:ok, result} <- GeofenceCrossing.validate_result(fence, from, to, policy, result),
         event when is_map(event) <- result["event"],
         :ok <- GeofenceCrossing.validate_event(event),
         {:ok, fence_document} <- Geofence.to_map(fence),
         {:ok, from_document} <- PositionSample.to_map(from),
         {:ok, to_document} <- PositionSample.to_map(to),
         {:ok, policy_document} <- GeofenceCrossing.to_map(policy),
         inputs = %{
           "schema" => "wtr.geofence-crossing-inputs.v1",
           "fence" => fence_document,
           "from" => from_document,
           "to" => to_document,
           "policy" => policy_document
         },
         {:ok, _encoded} <- Codec.encode(inputs, 262_144) do
      value = %{
        scope: scope,
        kind: @crossing_kind,
        rule_id: policy.id,
        inputs: inputs,
        result: result,
        event: event,
        mode: result["mode"],
        action: result["physical_action_dispatch"],
        evaluated_at: result["evaluated_at"]
      }

      {:ok, struct!(__MODULE__, Map.put(value, :identity, Codec.digest(identity_map(value))))}
    else
      _ -> {:error, :invalid_rule_event}
    end
  end

  @doc "Restores and re-evaluates suspicious movement before preparing its event intent."
  @spec suspicious_movement(String.t(), term(), term(), term(), term(), map()) ::
          {:ok, t()} | {:error, :invalid_rule_event}
  def suspicious_movement(scope, motion_state, armed, owner_presence, policy, result) do
    with true <- Codec.id?(scope),
         {:ok, result} <-
           SuspiciousMovement.validate_result(
             motion_state,
             armed,
             owner_presence,
             policy,
             result
           ),
         event when is_map(event) <- result["event"],
         :ok <- SuspiciousMovement.validate_event(event),
         {:ok, motion_document} <- MotionTransition.state_to_map(motion_state),
         {:ok, armed_document} <- PolicyFact.to_map(armed),
         {:ok, owner_document} <- PolicyFact.to_map(owner_presence),
         {:ok, policy_document} <- SuspiciousMovement.to_map(policy),
         inputs = %{
           "schema" => "wtr.suspicious-movement-inputs.v1",
           "motion_state" => motion_document,
           "armed" => armed_document,
           "owner_presence" => owner_document,
           "policy" => policy_document
         },
         {:ok, _encoded} <- Codec.encode(inputs, 262_144) do
      value = %{
        scope: scope,
        kind: @suspicious_kind,
        rule_id: policy.id,
        inputs: inputs,
        result: result,
        event: event,
        mode: result["mode"],
        action: result["physical_action_dispatch"],
        evaluated_at: result["evaluated_at"]
      }

      {:ok, struct!(__MODULE__, Map.put(value, :identity, Codec.digest(identity_map(value))))}
    else
      _ -> {:error, :invalid_rule_event}
    end
  end

  @doc "Rejects changed inputs, result, event, effect metadata or intent identity."
  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_rule_event}
  def validate(%__MODULE__{kind: @crossing_kind} = value), do: validate_crossing(value)
  def validate(%__MODULE__{kind: @suspicious_kind} = value), do: validate_suspicious(value)
  def validate(_), do: {:error, :invalid_rule_event}

  @doc false
  def event_identity(%__MODULE__{event: event}), do: event["id"]

  defp validate_crossing(value) do
    with true <- Codec.id?(value.scope) and Codec.id?(value.rule_id),
         true <- exact_fields?(value.inputs, @crossing_input_fields),
         true <- value.inputs["schema"] == "wtr.geofence-crossing-inputs.v1",
         {:ok, _encoded} <- Codec.encode(value.inputs, 262_144),
         {:ok, fence} <- Geofence.from_map(value.inputs["fence"]),
         {:ok, from} <- PositionSample.from_map(value.inputs["from"]),
         {:ok, to} <- PositionSample.from_map(value.inputs["to"]),
         {:ok, policy} <- GeofenceCrossing.from_map(value.inputs["policy"]),
         true <- policy.id == value.rule_id,
         {:ok, result} <-
           GeofenceCrossing.validate_result(fence, from, to, policy, value.result),
         true <- is_map(result["event"]) and result["event"] === value.event,
         true <- result["mode"] == value.mode,
         true <- result["physical_action_dispatch"] == value.action,
         true <- result["evaluated_at"] == value.evaluated_at,
         true <- value.mode in ~w(live replay),
         true <- value.action in ~w(prohibited separate_authorization_required),
         true <- Codec.time?(value.evaluated_at),
         true <- crossing_event_matches?(value.event, fence, from, to, policy),
         true <- Codec.id?(value.identity),
         true <- Codec.digest(identity_map(Map.from_struct(value))) == value.identity do
      {:ok, value}
    else
      _ -> {:error, :invalid_rule_event}
    end
  end

  defp validate_suspicious(value) do
    with true <- Codec.id?(value.scope) and Codec.id?(value.rule_id),
         true <- exact_fields?(value.inputs, @suspicious_input_fields),
         true <- value.inputs["schema"] == "wtr.suspicious-movement-inputs.v1",
         {:ok, _encoded} <- Codec.encode(value.inputs, 262_144),
         {:ok, motion_state} <-
           MotionTransition.state_from_map(value.inputs["motion_state"]),
         {:ok, armed} <- PolicyFact.from_map(value.inputs["armed"]),
         {:ok, owner_presence} <- PolicyFact.from_map(value.inputs["owner_presence"]),
         {:ok, policy} <- SuspiciousMovement.from_map(value.inputs["policy"]),
         true <- policy.id == value.rule_id,
         {:ok, result} <-
           SuspiciousMovement.validate_result(
             motion_state,
             armed,
             owner_presence,
             policy,
             value.result
           ),
         true <- is_map(result["event"]) and result["event"] === value.event,
         true <- result["mode"] == value.mode,
         true <- result["physical_action_dispatch"] == value.action,
         true <- result["evaluated_at"] == value.evaluated_at,
         true <- value.mode in ~w(live replay),
         true <- value.action in ~w(prohibited separate_authorization_required),
         true <- Codec.time?(value.evaluated_at),
         true <-
           suspicious_event_matches?(
             value.event,
             motion_state,
             armed,
             owner_presence,
             policy
           ),
         true <- Codec.id?(value.identity),
         true <- Codec.digest(identity_map(Map.from_struct(value))) == value.identity do
      {:ok, value}
    else
      _ -> {:error, :invalid_rule_event}
    end
  end

  defp crossing_event_matches?(event, fence, from, to, policy) do
    event["rule_id"] == policy.id and event["rule_identity"] == policy.identity and
      event["rule_revision"] == policy.revision and event["fence_id"] == fence.id and
      event["fence_identity"] == fence.identity and event["fence_revision"] == fence.revision and
      event["from_sample_identity"] == from.identity and
      event["to_sample_identity"] == to.identity
  end

  defp suspicious_event_matches?(event, motion_state, armed, owner_presence, policy) do
    event["rule_id"] == policy.id and event["policy_identity"] == policy.identity and
      event["rule_revision"] == policy.revision and
      event["motion_state_identity"] == motion_state.identity and
      event["active_trip_id"] == motion_state.active_trip.id and
      event["armed_fact_identity"] == armed.identity and
      event["owner_presence_fact_identity"] == owner_presence.identity and
      event["armed_evidence_id"] == armed.evidence.id and
      event["owner_presence_evidence_id"] == owner_presence.evidence.id
  end

  defp identity_map(value),
    do: %{
      "schema" => "wtr.rule-event.v1",
      "scope" => value.scope,
      "kind" => value.kind,
      "rule_id" => value.rule_id,
      "inputs" => value.inputs,
      "result" => value.result,
      "event" => value.event,
      "mode" => value.mode,
      "action" => value.action,
      "evaluated_at" => value.evaluated_at
    }

  defp exact_fields?(value, fields),
    do:
      is_map(value) and not is_struct(value) and
        Enum.sort(Map.keys(value)) == Enum.sort(fields)
end
