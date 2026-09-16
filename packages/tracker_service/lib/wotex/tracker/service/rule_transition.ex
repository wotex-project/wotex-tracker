defmodule Wotex.Tracker.Service.RuleTransition do
  @moduledoc """
  A closed transport-health state/event transition prepared by trusted host code.

  Construction re-evaluates the pure transition. The durable store receives only
  its native-JSON state, stable event intent and expected prior-state identity.
  """
  alias Wotex.Tracker.{
    BatteryTransition,
    HeartbeatTransition,
    MotionTransition,
    TransportDegradation
  }

  alias Wotex.Tracker.BatteryTransition.State, as: BatteryState
  alias Wotex.Tracker.HeartbeatTransition.State, as: HeartbeatState
  alias Wotex.Tracker.MotionTransition.State, as: MotionState
  alias Wotex.Tracker.Service.Codec
  alias Wotex.Tracker.TransportDegradation.State, as: TransportState

  @battery_kind "battery"
  @heartbeat_kind "heartbeat"
  @motion_kind "motion"
  @transport_kind "transport_degradation"
  @kinds [@battery_kind, @heartbeat_kind, @motion_kind, @transport_kind]
  @fields [
    :scope,
    :kind,
    :rule_id,
    :record_id,
    :expected_state_identity,
    :state_identity,
    :document,
    :event,
    :mode,
    :action,
    :evaluated_at,
    :identity
  ]
  @enforce_keys @fields
  defstruct @fields
  @type t :: %__MODULE__{}

  @doc "Revalidates and projects one pure transition for atomic host storage."
  @spec new(
          String.t(),
          BatteryState.t() | HeartbeatState.t() | MotionState.t() | TransportState.t() | nil,
          map()
        ) ::
          {:ok, t()} | {:error, atom()}
  def new(scope, previous, %{"schema" => "wtr.battery-transition.v1"} = result) do
    with true <- Codec.id?(scope),
         {:ok, result} <- BatteryTransition.validate_transition(previous, result),
         true <- result["state_changed"],
         %BatteryState{} = state <- result["state"],
         {:ok, document} <- BatteryTransition.state_to_map(state),
         :ok <- optional_event(@battery_kind, result["event"]),
         record_id = @battery_kind <> ":" <> state.policy.id,
         true <- Codec.id?(record_id) do
      transition(scope, @battery_kind, previous, state, document, result, record_id)
    else
      _ -> {:error, :invalid_rule_transition}
    end
  end

  def new(scope, previous, %{"schema" => "wtr.heartbeat-transition.v1"} = result) do
    with true <- Codec.id?(scope),
         {:ok, result} <- HeartbeatTransition.validate_transition(previous, result),
         true <- result["state_changed"],
         %HeartbeatState{} = state <- result["state"],
         {:ok, document} <- HeartbeatTransition.state_to_map(state),
         :ok <- optional_event(@heartbeat_kind, result["event"]),
         record_id = @heartbeat_kind <> ":" <> state.policy.id,
         true <- Codec.id?(record_id) do
      transition(
        scope,
        @heartbeat_kind,
        previous,
        state,
        document,
        result,
        record_id
      )
    else
      _ -> {:error, :invalid_rule_transition}
    end
  end

  def new(scope, previous, %{"schema" => "wtr.motion-transition.v1"} = result) do
    with true <- Codec.id?(scope),
         {:ok, result} <- MotionTransition.validate_transition(previous, result),
         true <- result["state_changed"],
         %MotionState{} = state <- result["state"],
         {:ok, document} <- MotionTransition.state_to_map(state),
         :ok <- optional_event(@motion_kind, result["event"]),
         true <- is_integer(result["evaluated_at"]),
         record_id = @motion_kind <> ":" <> state.policy.id,
         true <- Codec.id?(record_id) do
      transition(
        scope,
        @motion_kind,
        previous,
        state,
        document,
        result,
        record_id,
        result["evaluated_at"]
      )
    else
      _ -> {:error, :invalid_rule_transition}
    end
  end

  def new(scope, previous, result) do
    with true <- Codec.id?(scope),
         {:ok, result} <- TransportDegradation.validate_transition(previous, result),
         true <- result["state_changed"],
         %TransportState{} = state <- result["state"],
         {:ok, document} <- TransportDegradation.state_to_map(state),
         :ok <- optional_event(@transport_kind, result["event"]),
         record_id = @transport_kind <> ":" <> state.policy.id,
         true <- Codec.id?(record_id) do
      transition(
        scope,
        @transport_kind,
        previous,
        state,
        document,
        result,
        record_id
      )
    else
      _ -> {:error, :invalid_rule_transition}
    end
  end

  @doc "Rejects changed state, event, effect, expectation or transition identity."
  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_rule_transition}
  def validate(%__MODULE__{} = value) do
    with true <- value.kind in @kinds,
         true <- Enum.all?([value.scope, value.rule_id, value.record_id], &Codec.id?/1),
         true <- value.record_id == value.kind <> ":" <> value.rule_id,
         true <-
           is_nil(value.expected_state_identity) or Codec.id?(value.expected_state_identity),
         true <- Codec.id?(value.state_identity) and Codec.id?(value.identity),
         {:ok, state} <- restore_state(value.kind, value.document),
         true <- state.policy.id == value.rule_id,
         true <- state.identity == value.state_identity,
         true <- evaluated_at_matches?(value.kind, state, value.evaluated_at),
         true <- value.mode in ~w(live replay),
         true <- value.action in ~w(none prohibited separate_authorization_required),
         :ok <- optional_event(value.kind, value.event),
         true <- event_matches?(value.kind, value.event, state, value.mode, value.action),
         true <- Codec.digest(identity_map(Map.from_struct(value))) == value.identity do
      {:ok, value}
    else
      _ -> {:error, :invalid_rule_transition}
    end
  end

  def validate(_), do: {:error, :invalid_rule_transition}

  @doc false
  def event_identity(%__MODULE__{event: nil}), do: nil
  def event_identity(%__MODULE__{event: event}), do: event["id"]

  defp transition(scope, kind, previous, state, document, result, record_id) do
    transition(scope, kind, previous, state, document, result, record_id, state.evaluated_at)
  end

  defp transition(scope, kind, previous, state, document, result, record_id, evaluated_at) do
    value = %{
      scope: scope,
      kind: kind,
      rule_id: state.policy.id,
      record_id: record_id,
      expected_state_identity: if(previous, do: previous.identity, else: nil),
      state_identity: state.identity,
      document: document,
      event: result["event"],
      mode: result["mode"],
      action: result["physical_action_dispatch"],
      evaluated_at: evaluated_at
    }

    {:ok, struct!(__MODULE__, Map.put(value, :identity, Codec.digest(identity_map(value))))}
  end

  defp restore_state(@heartbeat_kind, document),
    do: HeartbeatTransition.state_from_map(document)

  defp restore_state(@battery_kind, document),
    do: BatteryTransition.state_from_map(document)

  defp restore_state(@motion_kind, document),
    do: MotionTransition.state_from_map(document)

  defp restore_state(@transport_kind, document),
    do: TransportDegradation.state_from_map(document)

  defp optional_event(_kind, nil), do: :ok

  defp optional_event(@battery_kind, event),
    do: BatteryTransition.validate_event(event)

  defp optional_event(@heartbeat_kind, event),
    do: HeartbeatTransition.validate_event(event)

  defp optional_event(@motion_kind, event),
    do: MotionTransition.validate_event(event)

  defp optional_event(@transport_kind, event),
    do: TransportDegradation.validate_event(event)

  defp event_matches?(_kind, nil, _state, "live", "none"), do: true
  defp event_matches?(_kind, nil, _state, "replay", "prohibited"), do: true

  defp event_matches?(@battery_kind, event, state, mode, action) when is_map(event) do
    expected_action =
      if(mode == "live", do: "separate_authorization_required", else: "prohibited")

    action == expected_action and event["rule_id"] == state.policy.id and
      event["policy_identity"] == state.policy.identity and
      event["rule_revision"] == state.policy.revision and event["to_status"] == state.status and
      event["to_sample_identity"] == state.sample.identity and
      event["to_evidence_id"] == state.sample.evidence.id and
      event["evaluated_at"] == state.evaluated_at
  end

  defp event_matches?(@transport_kind, event, state, mode, action) when is_map(event) do
    expected_action =
      if(mode == "live", do: "separate_authorization_required", else: "prohibited")

    action == expected_action and event["rule_id"] == state.policy.id and
      event["policy_identity"] == state.policy.identity and
      event["rule_revision"] == state.policy.revision and event["to_status"] == state.status and
      event["to_decision_identity"] == state.decision["decision_identity"] and
      event["evaluated_at"] == state.evaluated_at
  end

  defp event_matches?(@motion_kind, event, state, mode, action) when is_map(event) do
    expected_action =
      if(mode == "live", do: "separate_authorization_required", else: "prohibited")

    action == expected_action and event["rule_id"] == state.policy.id and
      event["policy_identity"] == state.policy.identity and
      event["rule_revision"] == state.policy.revision and
      event["to_sample_identity"] == state.order_sample.identity and
      event["to_position_evidence_id"] == state.order_sample.position.evidence_id and
      event["to_position_bundle_identity"] == state.order_sample.position.bundle_identity
  end

  defp event_matches?(@heartbeat_kind, event, state, mode, action) when is_map(event) do
    expected_action =
      if(mode == "live", do: "separate_authorization_required", else: "prohibited")

    action == expected_action and event["rule_id"] == state.policy.id and
      event["policy_identity"] == state.policy.identity and
      event["rule_revision"] == state.policy.revision and event["to_status"] == state.status and
      event["to_observation_identity"] == state.observation_identity and
      event["to_observation_id"] == state.observation.id and
      event["evaluated_at"] == state.evaluated_at
  end

  defp event_matches?(_, _, _, _, _), do: false

  defp evaluated_at_matches?(@motion_kind, _state, evaluated_at),
    do: is_integer(evaluated_at)

  defp evaluated_at_matches?(_kind, state, evaluated_at),
    do: state.evaluated_at == evaluated_at

  defp identity_map(value),
    do: %{
      "schema" => "wtr.rule-transition.v1",
      "scope" => value.scope,
      "kind" => value.kind,
      "rule_id" => value.rule_id,
      "record_id" => value.record_id,
      "expected_state_identity" => value.expected_state_identity,
      "state_identity" => value.state_identity,
      "document" => value.document,
      "event" => value.event,
      "mode" => value.mode,
      "action" => value.action,
      "evaluated_at" => value.evaluated_at
    }
end
