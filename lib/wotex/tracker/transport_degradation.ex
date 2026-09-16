defmodule Wotex.Tracker.TransportDegradation do
  @moduledoc """
  Pure transport-health state over content-identified policy decisions.

  A deployment explicitly names which qualified candidates count as healthy.
  Selected alternatives and no-route outcomes are degraded, while uncertain or
  stale delivery evidence remains unknown. Evaluation reads no clock and performs
  no send, queue or notification effect.
  """
  alias Wotex.Tracker.{Admission, Error, Limits, TransportPolicy}

  @fields ~w(id revision transport_policy healthy_candidate_ids maximum_decision_age_ms future_skew_ms)a
  @state_fields ~w(schema policy decision status evaluated_at identity)
  @policy_fields ~w(schema algorithm id revision transport_policy healthy_candidate_ids maximum_decision_age_ms future_skew_ms identity)
  @event_fields ~w(schema id algorithm rule_id previous_policy_identity policy_identity kind reason from_status to_status from_decision_identity to_decision_identity event_at rule_revision from_candidate_id to_candidate_id evaluated_at)
  @type t :: %__MODULE__{}
  @enforce_keys @fields ++ [:identity]
  defstruct @enforce_keys

  defmodule State do
    @moduledoc "Immutable transport health returned by `TransportDegradation.evaluate/6`."
    @type t :: %__MODULE__{}
    @enforce_keys [:policy, :decision, :status, :evaluated_at, :identity]
    defstruct @enforce_keys
  end

  @doc "Admits a rule, exact transport policy, healthy routes and decision freshness."
  @spec new(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(input, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         :ok <- Admission.fields(input, @fields),
         :ok <- Admission.each([input.id, input.revision], &Admission.id(&1, limits)),
         {:ok, transport_policy} <- TransportPolicy.validate(input.transport_policy, options),
         :ok <-
           healthy_candidates(
             input.healthy_candidate_ids,
             transport_policy,
             limits
           ),
         true <- duration?(input.maximum_decision_age_ms),
         true <- duration?(input.future_skew_ms),
         {:ok, identity} <-
           Admission.digest(policy_map(input, transport_policy), Limits.json(limits)) do
      {:ok,
       %__MODULE__{
         id: input.id,
         revision: input.revision,
         transport_policy: transport_policy,
         healthy_candidate_ids: input.healthy_candidate_ids,
         maximum_decision_age_ms: input.maximum_decision_age_ms,
         future_skew_ms: input.future_skew_ms,
         identity: identity
       }}
    else
      false -> Admission.fail(:invalid_input)
      error -> error
    end
  end

  @doc "Rejects modified health policy, route set, freshness or identity."
  @spec validate(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(value, options \\ [])

  def validate(%__MODULE__{} = policy, options) do
    with {:ok, admitted} <- new(Map.take(policy, @fields), options) do
      if admitted === policy, do: {:ok, admitted}, else: Admission.fail(:conflict)
    end
  end

  def validate(_, _), do: Admission.fail(:invalid_input)

  @doc "Revalidates the policy, decision, classification and state identity."
  @spec validate_state(term(), term()) :: {:ok, State.t()} | {:error, Error.t()}
  def validate_state(value, options \\ [])

  def validate_state(%State{} = value, options) do
    with {:ok, policy} <- validate(value.policy, options),
         {:ok, decision} <-
           TransportPolicy.validate_decision(
             value.decision,
             policy.transport_policy,
             options
           ),
         true <- is_integer(value.evaluated_at),
         {status, _reason} <- classify(decision, policy, value.evaluated_at),
         true <- status == value.status,
         {:ok, admitted} <- state(policy, decision, status, value.evaluated_at, options),
         true <- admitted === value do
      {:ok, admitted}
    else
      false -> Admission.fail(:conflict)
      error -> error
    end
  end

  def validate_state(_, _), do: Admission.fail(:invalid_input)

  @doc "Projects a validated state to closed native JSON for durable host storage."
  @spec state_to_map(term(), term()) :: {:ok, map()} | {:error, Error.t()}
  def state_to_map(state, options \\ []) do
    with {:ok, state} <- validate_state(state, options),
         {:ok, transport_policy} <- TransportPolicy.to_map(state.policy.transport_policy, options) do
      {:ok,
       %{
         "schema" => "wtr.transport-degradation-state.v1",
         "policy" => policy_document(state.policy, transport_policy),
         "decision" => state.decision,
         "status" => state.status,
         "evaluated_at" => state.evaluated_at,
         "identity" => state.identity
       }}
    end
  end

  @doc "Restores and revalidates a state from closed native JSON."
  @spec state_from_map(term(), term()) :: {:ok, State.t()} | {:error, Error.t()}
  def state_from_map(document, options \\ []) do
    with true <- exact_fields?(document, @state_fields),
         true <- document["schema"] == "wtr.transport-degradation-state.v1",
         {:ok, policy} <- policy_from_document(document["policy"], options),
         {:ok, decision} <-
           TransportPolicy.validate_decision(
             document["decision"],
             policy.transport_policy,
             options
           ),
         true <- document["status"] in ~w(healthy degraded unknown),
         true <- is_integer(document["evaluated_at"]),
         {:ok, state} <-
           state(policy, decision, document["status"], document["evaluated_at"], options),
         true <- state.identity == document["identity"] do
      {:ok, state}
    else
      false -> Admission.fail(:conflict)
      error -> error
    end
  end

  @doc "Re-evaluates a transition result and rejects changed state, event or effect fields."
  @spec validate_transition(term(), term(), term()) :: {:ok, map()} | {:error, Error.t()}
  def validate_transition(previous, result, options \\ []) do
    with {:ok, previous} <- previous(previous, options),
         true <- is_map(result) and not is_struct(result),
         %State{} = next_state <- result["state"],
         {:ok, next_state} <- validate_state(next_state, options),
         {:ok, mode} <- mode_atom(result["mode"]),
         {:ok, expected} <-
           evaluate(
             previous,
             next_state.decision,
             next_state.policy,
             mode,
             next_state.evaluated_at,
             options
           ),
         true <-
           Map.put(expected, "decision_outcome", result["decision_outcome"]) === result,
         :ok <- validate_optional_event(result["event"], options) do
      {:ok, result}
    else
      false -> Admission.fail(:conflict)
      error -> error
    end
  end

  @doc "Revalidates a stable transport degradation event and its content identity."
  @spec validate_event(term(), term()) :: :ok | {:error, Error.t()}
  def validate_event(event, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         true <- exact_fields?(event, @event_fields),
         :ok <- Admission.object(event, limits),
         true <- event_shape?(event, limits),
         {:ok, identity} <- Admission.digest(event_key(event), Limits.json(limits)),
         true <- identity == event["id"] do
      :ok
    else
      false -> Admission.fail(:conflict)
      error -> error
    end
  end

  @doc "Evaluates a decision or explicit time tick in live/replay mode."
  @spec evaluate(term(), term(), term(), term(), term(), term()) ::
          {:ok, map()} | {:error, Error.t()}
  def evaluate(previous, decision, policy, mode, now, options \\ []) do
    with {:ok, previous} <- previous(previous, options),
         {:ok, policy} <- validate(policy, options),
         {:ok, decision} <- optional_decision(decision, policy, options),
         true <- mode in [:live, :replay] and is_integer(now),
         :ok <- scope(previous, policy),
         {:ok, selected, outcome} <- select_decision(previous, decision) do
      evaluate_selected(previous, selected, outcome, policy, mode, now, options)
    else
      false -> Admission.fail(:invalid_input)
      error -> error
    end
  end

  defp previous(nil, _), do: {:ok, nil}
  defp previous(value, options), do: validate_state(value, options)
  defp optional_decision(nil, _policy, _options), do: {:ok, nil}

  defp optional_decision(value, policy, options),
    do: TransportPolicy.validate_decision(value, policy.transport_policy, options)

  defp scope(nil, _), do: :ok

  defp scope(previous, policy) do
    if previous.policy.id == policy.id,
      do: :ok,
      else: Admission.fail(:conflict)
  end

  defp select_decision(nil, nil), do: {:ok, nil, "tick"}
  defp select_decision(previous, nil), do: {:ok, previous.decision, "tick"}
  defp select_decision(nil, decision), do: {:ok, decision, "accepted"}

  defp select_decision(previous, decision) do
    cond do
      decision["decision_identity"] == previous.decision["decision_identity"] ->
        {:ok, previous.decision, "duplicate"}

      decision_key(decision) > decision_key(previous.decision) ->
        {:ok, decision, "accepted"}

      true ->
        {:ok, previous.decision, "historical"}
    end
  end

  defp evaluate_selected(nil, nil, outcome, _policy, mode, _now, _options),
    do:
      {:ok,
       result(
         nil,
         nil,
         nil,
         mode,
         "unknown",
         "missing_decision",
         outcome
       )}

  defp evaluate_selected(previous, decision, outcome, policy, mode, now, options) do
    if previous && now < previous.evaluated_at do
      {:ok,
       result(
         previous,
         previous,
         nil,
         mode,
         "unknown",
         "clock_regressed",
         outcome
       )}
    else
      {status, reason} = classify(decision, policy, now)

      with {:ok, next_state} <- state(policy, decision, status, now, options),
           {:ok, event, transition_status, transition_reason} <-
             transition(previous, next_state, reason, options) do
        {:ok,
         result(
           previous,
           next_state,
           event,
           mode,
           transition_status,
           transition_reason,
           outcome
         )}
      end
    end
  end

  defp classify(decision, policy, now) do
    age = now - decision["evaluated_at"]

    cond do
      age < -policy.future_skew_ms ->
        {"unknown", "decision_in_future"}

      age > policy.maximum_decision_age_ms ->
        {"unknown", "decision_stale"}

      decision["status"] in ~w(pending unknown) ->
        {"unknown", decision["reason"]}

      decision["status"] in ~w(deferred unavailable) ->
        {"degraded", decision["reason"]}

      candidate_id(decision) in policy.healthy_candidate_ids ->
        {"healthy", "healthy_candidate"}

      true ->
        {"degraded", "fallback_candidate"}
    end
  end

  defp transition(nil, _next, reason, _options),
    do: {:ok, nil, "baseline", reason}

  defp transition(previous, next_state, _reason, options)
       when previous.policy.identity != next_state.policy.identity do
    with {:ok, event} <-
           event(previous, next_state, "transport.recomputed", "rule_revised", options) do
      {:ok, event, "recomputed", "rule_revised"}
    end
  end

  defp transition(%{status: status}, %{status: status}, reason, _options),
    do: {:ok, nil, if(status == "unknown", do: "unknown", else: "stable"), reason}

  defp transition(previous, %{status: "degraded"} = next_state, reason, options) do
    with {:ok, event} <- event(previous, next_state, "transport.degraded", reason, options) do
      {:ok, event, "transition", reason}
    end
  end

  defp transition(
         %{status: "degraded"} = previous,
         %{status: "healthy"} = next_state,
         reason,
         options
       ) do
    with {:ok, event} <- event(previous, next_state, "transport.recovered", reason, options) do
      {:ok, event, "transition", reason}
    end
  end

  defp transition(_previous, _next_state, reason, _options),
    do:
      {:ok, nil,
       if(reason in ~w(decision_in_future decision_stale), do: "unknown", else: "baseline"),
       reason}

  defp state(policy, decision, status, now, options) do
    value = %{policy: policy, decision: decision, status: status, evaluated_at: now}

    with {:ok, limits} <- Limits.new(options),
         {:ok, identity} <- Admission.digest(state_map(value), Limits.json(limits)) do
      {:ok, struct!(State, Map.put(value, :identity, identity))}
    end
  end

  defp state_map(value),
    do: %{
      "schema" => "wtr.transport-degradation-state.v1",
      "algorithm" => "declared-healthy-candidate-v1",
      "policy_identity" => value.policy.identity,
      "transport_policy_identity" => value.policy.transport_policy.identity,
      "decision_identity" => value.decision["decision_identity"],
      "status" => value.status,
      "evaluated_at" => value.evaluated_at
    }

  defp event(previous, next_state, kind, reason, options) do
    identity_input = %{
      "schema" => "wtr.transport-degradation-event-key.v1",
      "algorithm" => "declared-healthy-candidate-v1",
      "rule_id" => next_state.policy.id,
      "previous_policy_identity" => previous.policy.identity,
      "policy_identity" => next_state.policy.identity,
      "kind" => kind,
      "reason" => reason,
      "from_status" => previous.status,
      "to_status" => next_state.status,
      "from_decision_identity" => previous.decision["decision_identity"],
      "to_decision_identity" => next_state.decision["decision_identity"],
      "event_at" => next_state.decision["evaluated_at"]
    }

    with {:ok, limits} <- Limits.new(options),
         {:ok, id} <- Admission.digest(identity_input, Limits.json(limits)) do
      {:ok,
       Map.merge(identity_input, %{
         "schema" => "wtr.transport-degradation-event.v1",
         "id" => id,
         "rule_revision" => next_state.policy.revision,
         "from_candidate_id" => candidate_id(previous.decision),
         "to_candidate_id" => candidate_id(next_state.decision),
         "evaluated_at" => next_state.evaluated_at
       })}
    end
  end

  defp result(previous, next_state, event, mode, status, reason, decision_outcome) do
    decision = if(next_state, do: next_state.decision, else: nil)

    %{
      "schema" => "wtr.transport-degradation-transition.v1",
      "status" => status,
      "reason" => reason,
      "mode" => Atom.to_string(mode),
      "decision_outcome" => decision_outcome,
      "decision_identity" => if(decision, do: decision["decision_identity"], else: nil),
      "request_id" => if(decision, do: decision["request_id"], else: nil),
      "candidate_id" => if(decision, do: candidate_id(decision), else: nil),
      "transport_status" => if(next_state, do: next_state.status, else: "unknown"),
      "state" => next_state,
      "state_changed" => state_identity(previous) != state_identity(next_state),
      "event" => event,
      "physical_action_dispatch" => action_effect(mode, event)
    }
  end

  defp candidate_id(%{"selected" => %{"candidate_id" => id}}), do: id
  defp candidate_id(%{"acknowledgement" => %{"candidate_id" => id}}), do: id
  defp candidate_id(_), do: nil

  defp state_identity(nil), do: nil
  defp state_identity(state), do: state.identity

  defp action_effect(:replay, _), do: "prohibited"
  defp action_effect(:live, nil), do: "none"
  defp action_effect(:live, _), do: "separate_authorization_required"

  defp decision_key(decision),
    do: [decision["evaluated_at"], decision["request_id"], decision["decision_identity"]]

  defp healthy_candidates(values, policy, limits) do
    available = Enum.uniq(policy.ordinary_order ++ policy.critical_order)

    with :ok <- Admission.ids(values, limits, limits.max_sources),
         true <- values != [] and Enum.all?(values, &(&1 in available)) do
      :ok
    else
      false -> Admission.fail(:conflict)
      error -> error
    end
  end

  defp duration?(value), do: is_integer(value) and value in 0..604_800_000

  defp policy_document(policy, transport_policy),
    do: %{
      "schema" => "wtr.transport-degradation-policy.v1",
      "algorithm" => "declared-healthy-candidate-v1",
      "id" => policy.id,
      "revision" => policy.revision,
      "transport_policy" => transport_policy,
      "healthy_candidate_ids" => policy.healthy_candidate_ids,
      "maximum_decision_age_ms" => policy.maximum_decision_age_ms,
      "future_skew_ms" => policy.future_skew_ms,
      "identity" => policy.identity
    }

  defp policy_from_document(document, options) do
    with true <- exact_fields?(document, @policy_fields),
         true <-
           document["schema"] == "wtr.transport-degradation-policy.v1" and
             document["algorithm"] == "declared-healthy-candidate-v1",
         {:ok, transport_policy} <-
           TransportPolicy.from_map(document["transport_policy"], options),
         {:ok, policy} <-
           new(
             %{
               id: document["id"],
               revision: document["revision"],
               transport_policy: transport_policy,
               healthy_candidate_ids: document["healthy_candidate_ids"],
               maximum_decision_age_ms: document["maximum_decision_age_ms"],
               future_skew_ms: document["future_skew_ms"]
             },
             options
           ),
         true <- policy.identity == document["identity"] do
      {:ok, policy}
    else
      false -> Admission.fail(:conflict)
      error -> error
    end
  end

  defp validate_optional_event(nil, _options), do: :ok
  defp validate_optional_event(event, options), do: validate_event(event, options)

  defp event_shape?(event, limits) do
    ids =
      ~w(id rule_id previous_policy_identity policy_identity reason from_decision_identity to_decision_identity rule_revision)

    event["schema"] == "wtr.transport-degradation-event.v1" and
      event["algorithm"] == "declared-healthy-candidate-v1" and
      Admission.each(Enum.map(ids, &event[&1]), &Admission.id(&1, limits)) == :ok and
      event_labels?(event) and
      optional_id?(event["from_candidate_id"], limits) and
      optional_id?(event["to_candidate_id"], limits) and event_times?(event)
  end

  defp event_labels?(event),
    do:
      event["kind"] in ~w(transport.degraded transport.recovered transport.recomputed) and
        event["from_status"] in ~w(healthy degraded unknown) and
        event["to_status"] in ~w(healthy degraded unknown)

  defp event_times?(event),
    do: is_integer(event["event_at"]) and is_integer(event["evaluated_at"])

  defp event_key(event),
    do: %{
      "schema" => "wtr.transport-degradation-event-key.v1",
      "algorithm" => event["algorithm"],
      "rule_id" => event["rule_id"],
      "previous_policy_identity" => event["previous_policy_identity"],
      "policy_identity" => event["policy_identity"],
      "kind" => event["kind"],
      "reason" => event["reason"],
      "from_status" => event["from_status"],
      "to_status" => event["to_status"],
      "from_decision_identity" => event["from_decision_identity"],
      "to_decision_identity" => event["to_decision_identity"],
      "event_at" => event["event_at"]
    }

  defp optional_id?(nil, _limits), do: true
  defp optional_id?(value, limits), do: Admission.id(value, limits) == :ok

  defp mode_atom("live"), do: {:ok, :live}
  defp mode_atom("replay"), do: {:ok, :replay}
  defp mode_atom(_), do: Admission.fail(:invalid_input)

  defp exact_fields?(value, fields),
    do:
      is_map(value) and not is_struct(value) and
        Enum.sort(Map.keys(value)) == Enum.sort(fields)

  defp policy_map(input, transport_policy),
    do: %{
      "schema" => "wtr.transport-degradation-policy.v1",
      "algorithm" => "declared-healthy-candidate-v1",
      "id" => input.id,
      "revision" => input.revision,
      "transport_policy_identity" => transport_policy.identity,
      "healthy_candidate_ids" => input.healthy_candidate_ids,
      "maximum_decision_age_ms" => input.maximum_decision_age_ms,
      "future_skew_ms" => input.future_skew_ms,
      "event_idempotency" => "transport-degradation-event-key-v1"
    }
end
