defmodule Wotex.Tracker.HeartbeatTransition do
  @moduledoc """
  Pure overdue-heartbeat state over admitted receiver observations.

  The caller supplies Unix time explicitly. A nil observation is a time tick;
  observations are ordered by receiver time and full content identity. Initial
  evaluation establishes a baseline instead of inventing a prior transition.
  """

  alias Wotex.Tracker.{Admission, Error, Limits, Observation}

  @fields ~w(id revision maximum_silence_ms future_skew_ms)a
  @serialized_policy_fields ~w(schema algorithm id revision maximum_silence_ms future_skew_ms threshold_equality initial_status event_idempotency identity)
  @state_fields ~w(schema policy observation observation_identity status due_at evaluated_at identity)
  @event_fields ~w(schema id algorithm rule_id previous_policy_identity policy_identity kind reason from_status to_status from_observation_identity to_observation_identity event_at rule_revision from_observation_id to_observation_id evaluated_at)
  @type t :: %__MODULE__{}
  @enforce_keys @fields ++ [:identity]
  defstruct @enforce_keys

  defmodule State do
    @moduledoc """
    Holds the heartbeat baseline and current overdue status.

    `Wotex.Tracker.HeartbeatTransition.evaluate/6` returns this immutable
    value with the last observation identity, due time, evaluation time, and
    content identity. A time tick can re-evaluate it without inventing a new
    receiver observation.
    """

    @type t :: %__MODULE__{}
    @enforce_keys [
      :policy,
      :observation,
      :observation_identity,
      :status,
      :due_at,
      :evaluated_at,
      :identity
    ]
    defstruct @enforce_keys
  end

  @doc "Admits silence and future-skew thresholds in integer milliseconds."
  @spec new(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(input, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         :ok <- Admission.fields(input, @fields),
         :ok <- Admission.each([input.id, input.revision], &Admission.id(&1, limits)),
         true <- duration?(input.maximum_silence_ms),
         true <- duration?(input.future_skew_ms),
         {:ok, identity} <- Admission.digest(policy_map(input), Limits.json(limits)) do
      {:ok, struct!(__MODULE__, Map.put(input, :identity, identity))}
    else
      false -> Admission.fail(:invalid_input)
      error -> error
    end
  end

  @doc "Rejects modified thresholds, scope, revision or identity."
  @spec validate(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(value, options \\ [])

  def validate(%__MODULE__{} = policy, options) do
    with {:ok, admitted} <- new(Map.take(policy, @fields), options) do
      if admitted === policy, do: {:ok, admitted}, else: Admission.fail(:conflict)
    end
  end

  def validate(_, _), do: Admission.fail(:invalid_input)

  @doc "Revalidates the observation, derived status, deadline and state identity."
  @spec validate_state(term(), term()) :: {:ok, State.t()} | {:error, Error.t()}
  def validate_state(value, options \\ [])

  def validate_state(%State{} = value, options) do
    with {:ok, policy} <- validate(value.policy, options),
         {:ok, observation} <- Observation.validate(value.observation, options),
         {:ok, observation_identity} <- Observation.identity(observation, options),
         true <- observation_identity == value.observation_identity,
         true <- is_integer(value.evaluated_at),
         true <- observation.observed_at <= value.evaluated_at + policy.future_skew_ms,
         true <- value.due_at == due_at(observation, policy),
         true <- value.status == heartbeat_status(observation, policy, value.evaluated_at),
         {:ok, admitted} <- state(policy, observation, value.evaluated_at, options),
         true <- admitted === value do
      {:ok, admitted}
    else
      false -> Admission.fail(:conflict)
      error -> error
    end
  end

  def validate_state(_, _), do: Admission.fail(:invalid_input)

  @doc "Projects a validated heartbeat policy to closed native JSON."
  @spec to_map(term(), term()) :: {:ok, map()} | {:error, Error.t()}
  def to_map(policy, options \\ []) do
    with {:ok, policy} <- validate(policy, options) do
      {:ok, Map.put(policy_map(policy), "identity", policy.identity)}
    end
  end

  @doc "Restores and revalidates a heartbeat policy from closed native JSON."
  @spec from_map(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(document, options \\ []) do
    with true <- exact_fields?(document, @serialized_policy_fields),
         true <-
           document["schema"] == "wtr.heartbeat-policy.v1" and
             document["algorithm"] == "receiver-silence-deadline-v1" and
             document["threshold_equality"] == "current" and
             document["initial_status"] == "baseline" and
             document["event_idempotency"] == "heartbeat-event-key-v1",
         {:ok, policy} <-
           new(
             %{
               id: document["id"],
               revision: document["revision"],
               maximum_silence_ms: document["maximum_silence_ms"],
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

  @doc "Projects a validated heartbeat state to closed native JSON for durable storage."
  @spec state_to_map(term(), term()) :: {:ok, map()} | {:error, Error.t()}
  def state_to_map(state, options \\ []) do
    with {:ok, state} <- validate_state(state, options),
         {:ok, policy} <- to_map(state.policy, options),
         {:ok, observation} <- Observation.to_map(state.observation, options) do
      {:ok,
       %{
         "schema" => "wtr.heartbeat-state.v1",
         "policy" => policy,
         "observation" => observation,
         "observation_identity" => state.observation_identity,
         "status" => state.status,
         "due_at" => state.due_at,
         "evaluated_at" => state.evaluated_at,
         "identity" => state.identity
       }}
    end
  end

  @doc "Restores and revalidates a heartbeat state from closed native JSON."
  @spec state_from_map(term(), term()) :: {:ok, State.t()} | {:error, Error.t()}
  def state_from_map(document, options \\ []) do
    with true <- exact_fields?(document, @state_fields),
         true <- document["schema"] == "wtr.heartbeat-state.v1",
         {:ok, policy} <- from_map(document["policy"], options),
         {:ok, observation} <- Observation.from_map(document["observation"], options),
         true <- document["status"] in ~w(current overdue),
         true <- is_integer(document["due_at"]) and is_integer(document["evaluated_at"]),
         {:ok, state} <- state(policy, observation, document["evaluated_at"], options),
         true <-
           state.observation_identity == document["observation_identity"] and
             state.status == document["status"] and state.due_at == document["due_at"] and
             state.identity == document["identity"] do
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
         true <- result["observation_outcome"] in ~w(accepted duplicate historical tick unknown),
         {:ok, expected} <-
           evaluate(
             previous,
             next_state.observation,
             next_state.policy,
             mode,
             next_state.evaluated_at,
             options
           ),
         true <-
           Map.put(expected, "observation_outcome", result["observation_outcome"]) === result,
         :ok <- validate_optional_event(result["event"], options) do
      {:ok, result}
    else
      false -> Admission.fail(:conflict)
      error -> error
    end
  end

  @doc "Revalidates a stable heartbeat event and its content identity."
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

  @doc "Evaluates an optional observation or time tick in `:live` or `:replay` mode."
  @spec evaluate(term(), term(), term(), term(), term(), term()) ::
          {:ok, map()} | {:error, Error.t()}
  def evaluate(previous, observation, policy, mode, now, options \\ []) do
    with {:ok, previous} <- previous(previous, options),
         {:ok, observation} <- optional_observation(observation, options),
         {:ok, policy} <- validate(policy, options),
         true <- mode in [:live, :replay] and is_integer(now),
         :ok <- scope(previous, policy) do
      context = %{
        previous: previous,
        observation: observation,
        policy: policy,
        mode: mode,
        now: now,
        edited: edited?(previous, policy),
        options: options
      }

      context
      |> evaluate_time()
      |> wrap_result()
    else
      false -> Admission.fail(:invalid_input)
      error -> error
    end
  end

  defp previous(nil, _), do: {:ok, nil}
  defp previous(state, options), do: validate_state(state, options)
  defp optional_observation(nil, _), do: {:ok, nil}
  defp optional_observation(value, options), do: Observation.validate(value, options)
  defp wrap_result({:error, _} = error), do: error
  defp wrap_result(result), do: {:ok, result}

  defp scope(nil, _), do: :ok

  defp scope(previous, policy) do
    if previous.policy.id == policy.id,
      do: :ok,
      else: Admission.fail(:conflict)
  end

  defp edited?(nil, _), do: false
  defp edited?(previous, policy), do: previous.policy.identity != policy.identity

  defp evaluate_time(%{previous: previous, now: now} = context)
       when not is_nil(previous) and now < previous.evaluated_at,
       do:
         result(
           previous,
           previous,
           nil,
           nil,
           context.mode,
           "unknown",
           "clock_regressed",
           "unknown"
         )

  defp evaluate_time(%{observation: nil, previous: nil} = context),
    do:
      result(
        nil,
        nil,
        nil,
        nil,
        context.mode,
        "unknown",
        "missing_observation",
        "tick"
      )

  defp evaluate_time(%{observation: observation, policy: policy, now: now} = context)
       when not is_nil(observation) and observation.observed_at > now + policy.future_skew_ms,
       do:
         result(
           context.previous,
           context.previous,
           nil,
           nil,
           context.mode,
           "unknown",
           "observation_in_future",
           "unknown"
         )

  defp evaluate_time(context) do
    with {:ok, observation, outcome} <- select_observation(context),
         {:ok, next_state} <- state(context.policy, observation, context.now, context.options) do
      transition(context, next_state, outcome)
    end
  end

  defp select_observation(%{observation: nil, previous: previous}),
    do: {:ok, previous.observation, "tick"}

  defp select_observation(%{observation: observation, previous: nil}),
    do: {:ok, observation, "accepted"}

  defp select_observation(%{observation: observation, previous: previous, options: options}) do
    with {:ok, identity} <- Observation.identity(observation, options) do
      cond do
        observation.id == previous.observation.id and
            identity != previous.observation_identity ->
          Admission.fail(:conflict)

        identity == previous.observation_identity ->
          {:ok, previous.observation, "duplicate"}

        observation_key(observation, identity) >
            observation_key(previous.observation, previous.observation_identity) ->
          {:ok, observation, "accepted"}

        true ->
          {:ok, previous.observation, "historical"}
      end
    end
  end

  defp transition(%{previous: nil} = context, next_state, outcome),
    do:
      result(
        nil,
        next_state,
        next_state.observation,
        nil,
        context.mode,
        "baseline",
        "initial_heartbeat",
        outcome
      )

  defp transition(%{edited: true} = context, next_state, outcome) do
    with {:ok, event} <- recomputed_event(context.previous, next_state, context.options) do
      result(
        context.previous,
        next_state,
        next_state.observation,
        event,
        context.mode,
        "recomputed",
        "rule_revised",
        outcome
      )
    end
  end

  defp transition(context, next_state, outcome) do
    previous = context.previous

    cond do
      previous.status == next_state.status ->
        result(
          previous,
          next_state,
          next_state.observation,
          nil,
          context.mode,
          "stable",
          "heartbeat_" <> next_state.status,
          outcome
        )

      next_state.status == "overdue" ->
        with {:ok, event} <- overdue_event(previous, next_state, context.options) do
          result(
            previous,
            next_state,
            next_state.observation,
            event,
            context.mode,
            "transition",
            "silence_threshold_exceeded",
            outcome
          )
        end

      true ->
        with {:ok, event} <- recovered_event(previous, next_state, context.options) do
          result(
            previous,
            next_state,
            next_state.observation,
            event,
            context.mode,
            "transition",
            "newer_heartbeat_received",
            outcome
          )
        end
    end
  end

  defp state(policy, observation, now, options) do
    with true <- observation.observed_at <= now + policy.future_skew_ms,
         {:ok, identity} <- Observation.identity(observation, options),
         {:ok, limits} <- Limits.new(options) do
      value = %{
        policy: policy,
        observation: observation,
        observation_identity: identity,
        status: heartbeat_status(observation, policy, now),
        due_at: due_at(observation, policy),
        evaluated_at: now
      }

      with {:ok, state_identity} <- Admission.digest(state_map(value), Limits.json(limits)) do
        {:ok, struct!(State, Map.put(value, :identity, state_identity))}
      end
    else
      false -> Admission.fail(:conflict)
      error -> error
    end
  end

  defp state_map(value),
    do: %{
      "schema" => "wtr.heartbeat-state.v1",
      "algorithm" => "receiver-silence-deadline-v1",
      "policy_identity" => value.policy.identity,
      "observation_id" => value.observation.id,
      "observation_identity" => value.observation_identity,
      "observed_at" => value.observation.observed_at,
      "status" => value.status,
      "due_at" => value.due_at,
      "evaluated_at" => value.evaluated_at
    }

  defp overdue_event(previous, next_state, options),
    do:
      event(
        previous,
        next_state,
        "heartbeat.overdue",
        "silence_threshold_exceeded",
        next_state.due_at,
        options
      )

  defp recovered_event(previous, next_state, options),
    do:
      event(
        previous,
        next_state,
        "heartbeat.recovered",
        "newer_heartbeat_received",
        next_state.observation.observed_at,
        options
      )

  defp recomputed_event(previous, next_state, options),
    do:
      event(
        previous,
        next_state,
        "heartbeat.recomputed",
        "rule_revised",
        next_state.evaluated_at,
        options
      )

  defp event(previous, next_state, kind, reason, event_at, options) do
    identity_input = %{
      "schema" => "wtr.heartbeat-event-key.v1",
      "algorithm" => "receiver-silence-deadline-v1",
      "rule_id" => next_state.policy.id,
      "previous_policy_identity" => previous.policy.identity,
      "policy_identity" => next_state.policy.identity,
      "kind" => kind,
      "reason" => reason,
      "from_status" => previous.status,
      "to_status" => next_state.status,
      "from_observation_identity" => previous.observation_identity,
      "to_observation_identity" => next_state.observation_identity,
      "event_at" => event_at
    }

    with {:ok, limits} <- Limits.new(options),
         {:ok, id} <- Admission.digest(identity_input, Limits.json(limits)) do
      {:ok,
       Map.merge(identity_input, %{
         "schema" => "wtr.heartbeat-event.v1",
         "id" => id,
         "rule_revision" => next_state.policy.revision,
         "from_observation_id" => previous.observation.id,
         "to_observation_id" => next_state.observation.id,
         "evaluated_at" => next_state.evaluated_at
       })}
    end
  end

  defp result(
         previous,
         next_state,
         observation,
         event,
         mode,
         status,
         reason,
         observation_outcome
       ) do
    %{
      "schema" => "wtr.heartbeat-transition.v1",
      "status" => status,
      "reason" => reason,
      "mode" => Atom.to_string(mode),
      "observation_outcome" => observation_outcome,
      "observation_id" => if(observation, do: observation.id, else: nil),
      "state" => next_state,
      "state_changed" => state_identity(previous) != state_identity(next_state),
      "heartbeat_status" => if(next_state, do: next_state.status, else: "unknown"),
      "age_ms" =>
        if(next_state,
          do: next_state.evaluated_at - next_state.observation.observed_at,
          else: nil
        ),
      "due_at" => if(next_state, do: next_state.due_at, else: nil),
      "event" => event,
      "physical_action_dispatch" => action_effect(mode, event)
    }
  end

  defp heartbeat_status(observation, policy, now) do
    if now <= observation.observed_at + policy.maximum_silence_ms,
      do: "current",
      else: "overdue"
  end

  defp due_at(observation, policy),
    do: observation.observed_at + policy.maximum_silence_ms + 1

  defp observation_key(observation, identity),
    do: [observation.observed_at, observation.id, identity]

  defp state_identity(nil), do: nil
  defp state_identity(state), do: state.identity

  defp action_effect(:replay, _), do: "prohibited"
  defp action_effect(:live, nil), do: "none"
  defp action_effect(:live, _), do: "separate_authorization_required"

  defp duration?(value), do: is_integer(value) and value in 0..604_800_000

  defp validate_optional_event(nil, _options), do: :ok
  defp validate_optional_event(event, options), do: validate_event(event, options)

  defp event_shape?(event, limits) do
    ids =
      ~w(id rule_id previous_policy_identity policy_identity reason from_observation_identity to_observation_identity rule_revision from_observation_id to_observation_id)

    event["schema"] == "wtr.heartbeat-event.v1" and
      event["algorithm"] == "receiver-silence-deadline-v1" and
      Admission.each(Enum.map(ids, &event[&1]), &Admission.id(&1, limits)) == :ok and
      event["kind"] in ~w(heartbeat.overdue heartbeat.recovered heartbeat.recomputed) and
      event["from_status"] in ~w(current overdue) and
      event["to_status"] in ~w(current overdue) and event_times?(event)
  end

  defp event_times?(event),
    do: is_integer(event["event_at"]) and is_integer(event["evaluated_at"])

  defp event_key(event),
    do: %{
      "schema" => "wtr.heartbeat-event-key.v1",
      "algorithm" => event["algorithm"],
      "rule_id" => event["rule_id"],
      "previous_policy_identity" => event["previous_policy_identity"],
      "policy_identity" => event["policy_identity"],
      "kind" => event["kind"],
      "reason" => event["reason"],
      "from_status" => event["from_status"],
      "to_status" => event["to_status"],
      "from_observation_identity" => event["from_observation_identity"],
      "to_observation_identity" => event["to_observation_identity"],
      "event_at" => event["event_at"]
    }

  defp mode_atom("live"), do: {:ok, :live}
  defp mode_atom("replay"), do: {:ok, :replay}
  defp mode_atom(_), do: Admission.fail(:invalid_input)

  defp exact_fields?(value, fields),
    do:
      is_map(value) and not is_struct(value) and
        Enum.sort(Map.keys(value)) == Enum.sort(fields)

  defp policy_map(input),
    do: %{
      "schema" => "wtr.heartbeat-policy.v1",
      "algorithm" => "receiver-silence-deadline-v1",
      "id" => input.id,
      "revision" => input.revision,
      "maximum_silence_ms" => input.maximum_silence_ms,
      "future_skew_ms" => input.future_skew_ms,
      "threshold_equality" => "current",
      "initial_status" => "baseline",
      "event_idempotency" => "heartbeat-event-key-v1"
    }
end
