defmodule Wotex.Tracker.SuspiciousMovement do
  @moduledoc """
  Three-valued suspicious-movement policy over motion, armed and owner facts.

  The rule is true only when motion is confirmed, the asset is armed and owner
  presence is false. Unknown owner presence remains unknown unless the policy
  explicitly elects to interpret it as absence.
  """
  alias Wotex.Tracker.{Admission, Error, Limits, MotionTransition, PolicyFact}

  @fields ~w(id revision motion_policy armed_predicate owner_presence_predicate maximum_fact_age_ms future_skew_ms owner_unknown_as_absent)a
  @type t :: %__MODULE__{}
  @enforce_keys @fields ++ [:identity]
  defstruct @enforce_keys

  @doc "Admits the motion policy, fact scopes, freshness and unknown interpretation."
  @spec new(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(input, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         :ok <- Admission.fields(input, @fields),
         :ok <-
           Admission.each(
             [input.id, input.revision, input.armed_predicate, input.owner_presence_predicate],
             &Admission.id(&1, limits)
           ),
         {:ok, motion_policy} <- MotionTransition.validate(input.motion_policy, options),
         true <- duration?(input.maximum_fact_age_ms),
         true <- duration?(input.future_skew_ms),
         true <- is_boolean(input.owner_unknown_as_absent),
         {:ok, identity} <-
           Admission.digest(policy_map(input, motion_policy), Limits.json(limits)) do
      {:ok,
       struct!(__MODULE__, Map.merge(input, %{motion_policy: motion_policy, identity: identity}))}
    else
      false -> Admission.fail(:invalid_input)
      error -> error
    end
  end

  @doc "Rejects modified nested policy, fact scope, timing or interpretation."
  @spec validate(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(value, options \\ [])

  def validate(%__MODULE__{} = policy, options) do
    with {:ok, admitted} <- new(Map.take(policy, @fields), options) do
      if admitted === policy, do: {:ok, admitted}, else: Admission.fail(:conflict)
    end
  end

  def validate(_, _), do: Admission.fail(:invalid_input)

  @doc "Evaluates the three evidence-backed inputs in explicit live/replay mode."
  @spec evaluate(term(), term(), term(), term(), term(), term(), term()) ::
          {:ok, map()} | {:error, Error.t()}
  def evaluate(motion_state, armed, owner_presence, policy, mode, now, options \\ []) do
    with {:ok, policy} <- validate(policy, options),
         {:ok, motion_state} <- MotionTransition.validate_state(motion_state, options),
         true <- motion_state.policy.identity == policy.motion_policy.identity,
         {:ok, armed} <- PolicyFact.validate(armed, options),
         {:ok, owner_presence} <- PolicyFact.validate(owner_presence, options),
         true <- armed.predicate == policy.armed_predicate,
         true <- owner_presence.predicate == policy.owner_presence_predicate,
         true <- mode in [:live, :replay] and is_integer(now),
         movement = movement_truth(motion_state),
         armed_truth = fact_truth(armed, policy, now),
         {owner_absent, interpretation} = owner_absence(owner_presence, policy, now),
         truth = conjunction([movement, armed_truth, owner_absent]),
         {:ok, event} <-
           event(
             truth,
             motion_state,
             armed,
             owner_presence,
             policy,
             interpretation,
             options
           ) do
      {:ok,
       %{
         "schema" => "wtr.suspicious-movement.v1",
         "status" => result_status(truth),
         "truth" => truth,
         "reason" => result_reason(truth),
         "mode" => Atom.to_string(mode),
         "conditions" => %{
           "movement" => movement,
           "armed" => armed_truth,
           "owner_absent" => owner_absent
         },
         "owner_unknown_interpretation" => interpretation,
         "motion_state_identity" => motion_state.identity,
         "armed_fact_identity" => armed.identity,
         "owner_presence_fact_identity" => owner_presence.identity,
         "policy_revision" => policy.revision,
         "policy_identity" => policy.identity,
         "evaluated_at" => now,
         "event" => event,
         "physical_action_dispatch" => action_effect(mode, event)
       }}
    else
      false -> Admission.fail(:conflict)
      error -> error
    end
  end

  defp movement_truth(%{motion_status: "moving"}), do: "true"
  defp movement_truth(%{motion_status: "stationary"}), do: "false"
  defp movement_truth(_), do: "unknown"

  defp fact_truth(fact, policy, now) do
    age = now - fact.observed_at

    if age < -policy.future_skew_ms or age > policy.maximum_fact_age_ms,
      do: "unknown",
      else: fact.status
  end

  defp owner_absence(fact, policy, now) do
    case fact_truth(fact, policy, now) do
      "true" -> {"false", "owner_present"}
      "false" -> {"true", "explicit_owner_absence"}
      "unknown" when policy.owner_unknown_as_absent -> {"true", "unknown_treated_as_absent"}
      "unknown" -> {"unknown", "unknown_retained"}
    end
  end

  defp conjunction(values) do
    cond do
      "false" in values -> "false"
      Enum.all?(values, &(&1 == "true")) -> "true"
      true -> "unknown"
    end
  end

  defp event("false", _motion, _armed, _owner, _policy, _interpretation, _options),
    do: {:ok, nil}

  defp event("unknown", _motion, _armed, _owner, _policy, _interpretation, _options),
    do: {:ok, nil}

  defp event("true", motion, armed, owner, policy, interpretation, options) do
    identity_input = %{
      "schema" => "wtr.suspicious-movement-event-key.v1",
      "algorithm" => "three-valued-armed-owner-motion-v1",
      "rule_id" => policy.id,
      "policy_identity" => policy.identity,
      "kind" => "suspicious_movement",
      "motion_state_identity" => motion.identity,
      "active_trip_id" => motion.active_trip.id,
      "armed_fact_identity" => armed.identity,
      "owner_presence_fact_identity" => owner.identity,
      "owner_unknown_interpretation" => interpretation
    }

    with {:ok, limits} <- Limits.new(options),
         {:ok, id} <- Admission.digest(identity_input, Limits.json(limits)) do
      {:ok,
       Map.merge(identity_input, %{
         "schema" => "wtr.suspicious-movement-event.v1",
         "id" => id,
         "rule_revision" => policy.revision,
         "movement_position_evidence_id" => motion.order_sample.position.evidence_id,
         "armed_evidence_id" => armed.evidence.id,
         "owner_presence_evidence_id" => owner.evidence.id
       })}
    end
  end

  defp result_status("true"), do: "triggered"
  defp result_status("false"), do: "clear"
  defp result_status("unknown"), do: "unknown"
  defp result_reason("true"), do: "all_conditions_true"
  defp result_reason("false"), do: "condition_false"
  defp result_reason("unknown"), do: "condition_unknown"

  defp action_effect(:replay, _), do: "prohibited"
  defp action_effect(:live, nil), do: "none"
  defp action_effect(:live, _), do: "separate_authorization_required"

  defp duration?(value), do: is_integer(value) and value in 0..604_800_000

  defp policy_map(input, motion_policy),
    do: %{
      "schema" => "wtr.suspicious-movement-policy.v1",
      "algorithm" => "three-valued-armed-owner-motion-v1",
      "id" => input.id,
      "revision" => input.revision,
      "motion_policy_identity" => motion_policy.identity,
      "armed_predicate" => input.armed_predicate,
      "owner_presence_predicate" => input.owner_presence_predicate,
      "maximum_fact_age_ms" => input.maximum_fact_age_ms,
      "future_skew_ms" => input.future_skew_ms,
      "owner_unknown_as_absent" => input.owner_unknown_as_absent,
      "event_idempotency" => "suspicious-movement-event-key-v1"
    }
end
