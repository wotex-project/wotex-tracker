defmodule Wotex.Tracker.BatteryTransition do
  @moduledoc """
  Pure low-battery state and recovery transitions over measurement evidence.

  Policies name the exact measurement kind/unit, separate low and clear
  thresholds, freshness, future skew and suspect-quality treatment.
  """

  alias Wotex.Tracker.{Admission, Error, Limits, MeasurementSample}

  @fields ~w(id revision measurement_kind unit low_threshold clear_threshold maximum_age_ms future_skew_ms accept_suspect)a
  @serialized_policy_fields ~w(schema algorithm id revision measurement_kind unit low_threshold clear_threshold maximum_age_ms future_skew_ms accept_suspect threshold_equality event_idempotency identity)
  @state_fields ~w(schema policy sample status evaluated_at identity)
  @event_fields ~w(schema id algorithm rule_id previous_policy_identity policy_identity kind reason from_status to_status from_sample_identity to_sample_identity event_at rule_revision measurement_kind unit from_evidence_id to_evidence_id evaluated_at)
  @type t :: %__MODULE__{}
  @enforce_keys @fields ++ [:identity]
  defstruct @enforce_keys

  defmodule State do
    @moduledoc """
    Holds the evaluated low-battery status and its source sample.

    `Wotex.Tracker.BatteryTransition.evaluate/6` returns this immutable value
    with the admitted policy, evaluation time, and content identity. The
    transition checks age, quality, and hysteresis before changing status.
    """

    @type t :: %__MODULE__{}
    @enforce_keys [:policy, :sample, :status, :evaluated_at, :identity]
    defstruct @enforce_keys
  end

  @doc "Admits evidence kind/unit, hysteresis, age, skew and quality policy."
  @spec new(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(input, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         :ok <- Admission.fields(input, @fields),
         :ok <-
           Admission.each(
             [input.id, input.revision, input.measurement_kind, input.unit],
             &Admission.id(&1, limits)
           ),
         true <- finite?(input.low_threshold),
         true <- finite?(input.clear_threshold),
         true <- input.low_threshold < input.clear_threshold,
         true <- duration?(input.maximum_age_ms),
         true <- duration?(input.future_skew_ms),
         true <- is_boolean(input.accept_suspect),
         {:ok, identity} <- Admission.digest(policy_map(input), Limits.json(limits)) do
      {:ok, struct!(__MODULE__, Map.put(input, :identity, identity))}
    else
      false -> Admission.fail(:invalid_input)
      error -> error
    end
  end

  @doc "Rejects modified measurement, hysteresis, time, quality or identity policy."
  @spec validate(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(value, options \\ [])

  def validate(%__MODULE__{} = policy, options) do
    with {:ok, admitted} <- new(Map.take(policy, @fields), options) do
      if admitted === policy, do: {:ok, admitted}, else: Admission.fail(:conflict)
    end
  end

  def validate(_, _), do: Admission.fail(:invalid_input)

  @doc "Revalidates sample scope, current classification and state identity."
  @spec validate_state(term(), term()) :: {:ok, State.t()} | {:error, Error.t()}
  def validate_state(value, options \\ [])

  def validate_state(%State{} = value, options) do
    with {:ok, policy} <- validate(value.policy, options),
         {:ok, sample} <- MeasurementSample.validate(value.sample, options),
         :ok <- sample_scope(sample, policy),
         true <- is_integer(value.evaluated_at),
         true <- value.status in ~w(unknown normal low),
         {:ok, classified, reason, _age} <- classify(sample, policy, value.evaluated_at, nil),
         true <- state_status_valid?(value.status, classified, reason),
         {:ok, admitted} <- state(policy, sample, value.status, value.evaluated_at, options),
         true <- admitted === value do
      {:ok, admitted}
    else
      false -> Admission.fail(:conflict)
      error -> error
    end
  end

  def validate_state(_, _), do: Admission.fail(:invalid_input)

  @doc "Projects a validated battery policy to closed native JSON."
  @spec to_map(term(), term()) :: {:ok, map()} | {:error, Error.t()}
  def to_map(policy, options \\ []) do
    with {:ok, policy} <- validate(policy, options) do
      {:ok, Map.put(policy_map(policy), "identity", policy.identity)}
    end
  end

  @doc "Restores and revalidates a battery policy from closed native JSON."
  @spec from_map(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(document, options \\ []) do
    with true <- exact_fields?(document, @serialized_policy_fields),
         true <-
           document["schema"] == "wtr.battery-policy.v1" and
             document["algorithm"] == "fresh-measurement-hysteresis-v1" and
             document["threshold_equality"] == "included" and
             document["event_idempotency"] == "battery-event-key-v1",
         {:ok, policy} <-
           new(
             %{
               id: document["id"],
               revision: document["revision"],
               measurement_kind: document["measurement_kind"],
               unit: document["unit"],
               low_threshold: document["low_threshold"],
               clear_threshold: document["clear_threshold"],
               maximum_age_ms: document["maximum_age_ms"],
               future_skew_ms: document["future_skew_ms"],
               accept_suspect: document["accept_suspect"]
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

  @doc "Projects a validated battery state to closed native JSON for durable storage."
  @spec state_to_map(term(), term()) :: {:ok, map()} | {:error, Error.t()}
  def state_to_map(state, options \\ []) do
    with {:ok, state} <- validate_state(state, options),
         {:ok, policy} <- to_map(state.policy, options),
         {:ok, sample} <- MeasurementSample.to_map(state.sample, options) do
      {:ok,
       %{
         "schema" => "wtr.battery-state.v1",
         "policy" => policy,
         "sample" => sample,
         "status" => state.status,
         "evaluated_at" => state.evaluated_at,
         "identity" => state.identity
       }}
    end
  end

  @doc "Restores and revalidates a battery state from closed native JSON."
  @spec state_from_map(term(), term()) :: {:ok, State.t()} | {:error, Error.t()}
  def state_from_map(document, options \\ []) do
    with true <- exact_fields?(document, @state_fields),
         true <- document["schema"] == "wtr.battery-state.v1",
         {:ok, policy} <- from_map(document["policy"], options),
         {:ok, sample} <- MeasurementSample.from_map(document["sample"], options),
         true <- document["status"] in ~w(unknown normal low),
         true <- is_integer(document["evaluated_at"]),
         :ok <- sample_scope(sample, policy),
         {:ok, state} <-
           state(policy, sample, document["status"], document["evaluated_at"], options),
         true <- state.identity == document["identity"],
         {:ok, state} <- validate_state(state, options) do
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
         true <- result["sample_outcome"] in ~w(accepted duplicate historical tick unknown),
         {:ok, expected} <-
           evaluate(
             previous,
             next_state.sample,
             next_state.policy,
             mode,
             next_state.evaluated_at,
             options
           ),
         true <- Map.put(expected, "sample_outcome", result["sample_outcome"]) === result,
         :ok <- validate_optional_event(result["event"], options) do
      {:ok, result}
    else
      false -> Admission.fail(:conflict)
      error -> error
    end
  end

  @doc "Revalidates a stable battery event and its content identity."
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

  @doc "Evaluates an optional measurement sample or age tick in live/replay mode."
  @spec evaluate(term(), term(), term(), term(), term(), term()) ::
          {:ok, map()} | {:error, Error.t()}
  def evaluate(previous, sample, policy, mode, now, options \\ []) do
    with {:ok, previous} <- previous(previous, options),
         {:ok, sample} <- optional_sample(sample, options),
         {:ok, policy} <- validate(policy, options),
         true <- mode in [:live, :replay] and is_integer(now),
         :ok <- scope(previous, policy),
         :ok <- optional_scope(sample, policy) do
      context = %{
        previous: previous,
        sample: sample,
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
  defp optional_sample(nil, _), do: {:ok, nil}
  defp optional_sample(sample, options), do: MeasurementSample.validate(sample, options)
  defp wrap_result({:error, _} = error), do: error
  defp wrap_result(result), do: {:ok, result}

  defp scope(nil, _), do: :ok

  defp scope(previous, policy) do
    if previous.policy.id == policy.id,
      do: :ok,
      else: Admission.fail(:conflict)
  end

  defp optional_scope(nil, _), do: :ok
  defp optional_scope(sample, policy), do: sample_scope(sample, policy)

  defp sample_scope(sample, policy) do
    measurement = sample.measurement

    if measurement.kind == policy.measurement_kind and measurement.unit == policy.unit and
         (is_number(measurement.value) or measurement.availability == :unavailable),
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
           {"unknown", "clock_regressed", "unknown", nil}
         )

  defp evaluate_time(%{sample: nil, previous: nil} = context),
    do:
      result(
        nil,
        nil,
        nil,
        nil,
        context.mode,
        {"unknown", "missing_measurement", "tick", nil}
      )

  defp evaluate_time(context) do
    with {:ok, sample, outcome} <- select_sample(context),
         previous_status =
           if(context.previous && not context.edited, do: context.previous.status, else: nil),
         {:ok, status, reason, age} <-
           classify(sample, context.policy, context.now, previous_status),
         {:ok, next_state} <-
           state(context.policy, sample, status, context.now, context.options) do
      transition(context, next_state, outcome, reason, age)
    end
  end

  defp select_sample(%{sample: nil, previous: previous}),
    do: {:ok, previous.sample, "tick"}

  defp select_sample(%{sample: sample, previous: nil}), do: {:ok, sample, "accepted"}

  defp select_sample(%{sample: sample, previous: previous}) do
    cond do
      sample.evidence.id == previous.sample.evidence.id and
          sample.identity != previous.sample.identity ->
        Admission.fail(:conflict)

      sample.identity == previous.sample.identity ->
        {:ok, previous.sample, "duplicate"}

      sample_key(sample) > sample_key(previous.sample) ->
        {:ok, sample, "accepted"}

      true ->
        {:ok, previous.sample, "historical"}
    end
  end

  defp classify(sample, policy, now, previous_status) do
    age = now - sample.observed_at

    cond do
      age < -policy.future_skew_ms ->
        {:ok, "unknown", "measurement_in_future", age}

      age > policy.maximum_age_ms ->
        {:ok, "unknown", "measurement_stale", age}

      true ->
        classify_measurement(sample.measurement, policy, previous_status, age)
    end
  end

  defp classify_measurement(measurement, policy, previous_status, age) do
    cond do
      measurement.availability != :available ->
        {:ok, "unknown", "measurement_unavailable", age}

      measurement.quality == :suspect and not policy.accept_suspect ->
        {:ok, "unknown", "suspect_measurement_rejected", age}

      measurement.value <= policy.low_threshold ->
        {:ok, "low", "low_threshold_met", age}

      measurement.value >= policy.clear_threshold ->
        {:ok, "normal", "clear_threshold_met", age}

      previous_status in ~w(low normal) ->
        {:ok, previous_status, "hysteresis_retained", age}

      true ->
        {:ok, "unknown", "hysteresis_without_baseline", age}
    end
  end

  defp transition(%{previous: nil} = context, next_state, outcome, reason, age),
    do:
      result(
        nil,
        next_state,
        next_state.sample,
        nil,
        context.mode,
        {"baseline", reason, outcome, age}
      )

  defp transition(%{edited: true} = context, next_state, outcome, _reason, age) do
    with {:ok, event} <- recomputed_event(context.previous, next_state, context.options) do
      result(
        context.previous,
        next_state,
        next_state.sample,
        event,
        context.mode,
        {"recomputed", "rule_revised", outcome, age}
      )
    end
  end

  defp transition(context, next_state, outcome, reason, age) do
    previous = context.previous

    cond do
      previous.status == next_state.status ->
        result(
          previous,
          next_state,
          next_state.sample,
          nil,
          context.mode,
          {
            if(next_state.status == "unknown", do: "unknown", else: "stable"),
            reason,
            outcome,
            age
          }
        )

      next_state.status == "low" ->
        with {:ok, event} <-
               battery_event(previous, next_state, "battery.low", reason, context.options) do
          result(
            previous,
            next_state,
            next_state.sample,
            event,
            context.mode,
            {"transition", reason, outcome, age}
          )
        end

      previous.status == "low" and next_state.status == "normal" ->
        with {:ok, event} <-
               battery_event(
                 previous,
                 next_state,
                 "battery.recovered",
                 reason,
                 context.options
               ) do
          result(
            previous,
            next_state,
            next_state.sample,
            event,
            context.mode,
            {"transition", reason, outcome, age}
          )
        end

      true ->
        result(
          previous,
          next_state,
          next_state.sample,
          nil,
          context.mode,
          {
            if(next_state.status == "unknown", do: "unknown", else: "baseline"),
            reason,
            outcome,
            age
          }
        )
    end
  end

  defp state(policy, sample, status, now, options) do
    value = %{policy: policy, sample: sample, status: status, evaluated_at: now}

    with {:ok, limits} <- Limits.new(options),
         {:ok, identity} <- Admission.digest(state_map(value), Limits.json(limits)) do
      {:ok, struct!(State, Map.put(value, :identity, identity))}
    end
  end

  defp state_map(value),
    do: %{
      "schema" => "wtr.battery-state.v1",
      "algorithm" => "fresh-measurement-hysteresis-v1",
      "policy_identity" => value.policy.identity,
      "sample_identity" => value.sample.identity,
      "status" => value.status,
      "evaluated_at" => value.evaluated_at
    }

  defp recomputed_event(previous, next_state, options),
    do:
      battery_event(
        previous,
        next_state,
        "battery.recomputed",
        "rule_revised",
        options
      )

  defp battery_event(previous, next_state, kind, reason, options) do
    identity_input = %{
      "schema" => "wtr.battery-event-key.v1",
      "algorithm" => "fresh-measurement-hysteresis-v1",
      "rule_id" => next_state.policy.id,
      "previous_policy_identity" => previous.policy.identity,
      "policy_identity" => next_state.policy.identity,
      "kind" => kind,
      "reason" => reason,
      "from_status" => previous.status,
      "to_status" => next_state.status,
      "from_sample_identity" => previous.sample.identity,
      "to_sample_identity" => next_state.sample.identity,
      "event_at" => next_state.sample.observed_at
    }

    with {:ok, limits} <- Limits.new(options),
         {:ok, id} <- Admission.digest(identity_input, Limits.json(limits)) do
      {:ok,
       Map.merge(identity_input, %{
         "schema" => "wtr.battery-event.v1",
         "id" => id,
         "rule_revision" => next_state.policy.revision,
         "measurement_kind" => next_state.policy.measurement_kind,
         "unit" => next_state.policy.unit,
         "from_evidence_id" => previous.sample.evidence.id,
         "to_evidence_id" => next_state.sample.evidence.id,
         "evaluated_at" => next_state.evaluated_at
       })}
    end
  end

  defp result(previous, next_state, sample, event, mode, {status, reason, outcome, age}) do
    %{
      "schema" => "wtr.battery-transition.v1",
      "status" => status,
      "reason" => reason,
      "mode" => Atom.to_string(mode),
      "sample_outcome" => outcome,
      "sample_identity" => if(sample, do: sample.identity, else: nil),
      "measurement_evidence_id" => if(sample, do: sample.evidence.id, else: nil),
      "battery_status" => if(next_state, do: next_state.status, else: "unknown"),
      "value" => if(sample, do: sample.measurement.value, else: nil),
      "unit" => if(sample, do: sample.measurement.unit, else: nil),
      "age_ms" => age,
      "state" => next_state,
      "state_changed" => state_identity(previous) != state_identity(next_state),
      "event" => event,
      "physical_action_dispatch" => action_effect(mode, event)
    }
  end

  defp state_status_valid?(status, classified, _reason) when classified in ~w(low normal),
    do: status == classified

  defp state_status_valid?(status, "unknown", "hysteresis_without_baseline"),
    do: status in ~w(unknown low normal)

  defp state_status_valid?(status, "unknown", _reason), do: status == "unknown"

  defp sample_key(sample),
    do: [sample.observed_at, sample.observation_id, sample.evidence.id, sample.identity]

  defp state_identity(nil), do: nil
  defp state_identity(state), do: state.identity

  defp action_effect(:replay, _), do: "prohibited"
  defp action_effect(:live, nil), do: "none"
  defp action_effect(:live, _), do: "separate_authorization_required"

  defp finite?(value),
    do: is_number(value) and value >= -1_000_000_000 and value <= 1_000_000_000

  defp duration?(value), do: is_integer(value) and value in 0..604_800_000

  defp validate_optional_event(nil, _options), do: :ok
  defp validate_optional_event(event, options), do: validate_event(event, options)

  defp event_shape?(event, limits) do
    ids =
      ~w(id rule_id previous_policy_identity policy_identity reason from_sample_identity to_sample_identity rule_revision measurement_kind unit from_evidence_id to_evidence_id)

    event["schema"] == "wtr.battery-event.v1" and
      event["algorithm"] == "fresh-measurement-hysteresis-v1" and
      Admission.each(Enum.map(ids, &event[&1]), &Admission.id(&1, limits)) == :ok and
      event["kind"] in ~w(battery.low battery.recovered battery.recomputed) and
      event["from_status"] in ~w(unknown normal low) and
      event["to_status"] in ~w(unknown normal low) and event_times?(event)
  end

  defp event_times?(event),
    do: is_integer(event["event_at"]) and is_integer(event["evaluated_at"])

  defp event_key(event),
    do: %{
      "schema" => "wtr.battery-event-key.v1",
      "algorithm" => event["algorithm"],
      "rule_id" => event["rule_id"],
      "previous_policy_identity" => event["previous_policy_identity"],
      "policy_identity" => event["policy_identity"],
      "kind" => event["kind"],
      "reason" => event["reason"],
      "from_status" => event["from_status"],
      "to_status" => event["to_status"],
      "from_sample_identity" => event["from_sample_identity"],
      "to_sample_identity" => event["to_sample_identity"],
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
      "schema" => "wtr.battery-policy.v1",
      "algorithm" => "fresh-measurement-hysteresis-v1",
      "id" => input.id,
      "revision" => input.revision,
      "measurement_kind" => input.measurement_kind,
      "unit" => input.unit,
      "low_threshold" => input.low_threshold,
      "clear_threshold" => input.clear_threshold,
      "maximum_age_ms" => input.maximum_age_ms,
      "future_skew_ms" => input.future_skew_ms,
      "accept_suspect" => input.accept_suspect,
      "threshold_equality" => "included",
      "event_idempotency" => "battery-event-key-v1"
    }
end
