defmodule Wotex.Tracker.MotionTransition do
  @moduledoc """
  Pure dwell-based motion and trip transitions over ordered position samples.

  A first moving or stationary segment starts a candidate interval. A later
  segment of the same class must confirm the configured dwell before canonical
  motion changes, so one speed spike cannot establish a trip.
  """
  alias Wotex.Tracker.{Admission, Error, Limits, PositionMovement, PositionOrder, PositionSample}

  @fields ~w(id revision movement_policy minimum_movement_ms minimum_stop_ms)a
  @type t :: %__MODULE__{}
  @enforce_keys @fields ++ [:identity]
  defstruct @enforce_keys

  defmodule Trip do
    @moduledoc "A content-identified active trip established by movement dwell."
    @type t :: %__MODULE__{}
    @enforce_keys [
      :id,
      :policy_identity,
      :started_at,
      :confirmed_at,
      :start_sample,
      :confirmation_sample
    ]
    defstruct @enforce_keys
  end

  defmodule State do
    @moduledoc "Immutable motion state returned by `MotionTransition.evaluate/6`."
    @type t :: %__MODULE__{}
    @enforce_keys [
      :policy,
      :order_sample,
      :last_received_sample,
      :last_received_outcome,
      :segment_sample,
      :motion_status,
      :candidate_status,
      :candidate_since,
      :candidate_sample,
      :active_trip,
      :identity
    ]
    defstruct @enforce_keys
  end

  @doc "Admits the movement classifier and consecutive-evidence dwell durations."
  @spec new(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(input, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         :ok <- Admission.fields(input, @fields),
         :ok <- Admission.each([input.id, input.revision], &Admission.id(&1, limits)),
         {:ok, movement_policy} <- PositionMovement.validate(input.movement_policy, options),
         true <- duration?(input.minimum_movement_ms),
         true <- duration?(input.minimum_stop_ms),
         {:ok, identity} <-
           Admission.digest(policy_map(input, movement_policy), Limits.json(limits)) do
      {:ok,
       %__MODULE__{
         id: input.id,
         revision: input.revision,
         movement_policy: movement_policy,
         minimum_movement_ms: input.minimum_movement_ms,
         minimum_stop_ms: input.minimum_stop_ms,
         identity: identity
       }}
    else
      false -> Admission.fail(:invalid_input)
      error -> error
    end
  end

  @doc "Rejects modified dwell, classifier or identity content."
  @spec validate(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(value, options \\ [])

  def validate(%__MODULE__{} = policy, options) do
    with {:ok, admitted} <- new(Map.take(policy, @fields), options) do
      if admitted === policy, do: {:ok, admitted}, else: Admission.fail(:conflict)
    end
  end

  def validate(_, _), do: Admission.fail(:invalid_input)

  @doc "Revalidates the policy, samples, candidate, active trip and state identity."
  @spec validate_state(term(), term()) :: {:ok, State.t()} | {:error, Error.t()}
  def validate_state(value, options \\ [])

  def validate_state(%State{} = value, options) do
    with {:ok, policy} <- validate(value.policy, options),
         {:ok, order_sample} <- PositionSample.validate(value.order_sample, options),
         {:ok, received_sample} <- PositionSample.validate(value.last_received_sample, options),
         true <- value.last_received_outcome in ~w(accepted duplicate historical unknown),
         true <- received_key(received_sample) >= received_key(order_sample),
         {:ok, segment_sample} <- optional_sample(value.segment_sample, options),
         true <- is_nil(segment_sample) or segment_sample.identity == order_sample.identity,
         true <- value.motion_status in ~w(unknown stationary moving),
         {:ok, candidate_status, candidate_since, candidate_sample} <-
           candidate(
             value.candidate_status,
             value.candidate_since,
             value.candidate_sample,
             policy,
             options
           ),
         true <- candidate_pending?(candidate_status, candidate_since, order_sample, policy),
         true <- candidate_status != value.motion_status,
         {:ok, active_trip} <- active_trip(value.active_trip, policy, options),
         true <- trip_matches_motion?(active_trip, value.motion_status),
         {:ok, admitted} <-
           state(
             state_values(
               policy,
               order_sample,
               received_sample,
               value.last_received_outcome,
               segment_sample,
               value.motion_status,
               {candidate_status, candidate_since, candidate_sample},
               active_trip
             ),
             options
           ),
         true <- admitted === value do
      {:ok, admitted}
    else
      false -> Admission.fail(:conflict)
      error -> error
    end
  end

  def validate_state(_, _), do: Admission.fail(:invalid_input)

  @doc "Evaluates one sample in explicit `:live` or `:replay` mode."
  @spec evaluate(term(), term(), term(), term(), term(), term()) ::
          {:ok, map()} | {:error, Error.t()}
  def evaluate(previous, sample, policy, mode, now, options \\ []) do
    with {:ok, previous} <- previous(previous, options),
         {:ok, sample} <- PositionSample.validate(sample, options),
         {:ok, policy} <- validate(policy, options),
         true <- mode in [:live, :replay] and is_integer(now),
         :ok <- scope(previous, policy),
         :ok <- edit_sample(previous, policy, sample) do
      edited = edited?(previous, policy)
      order_previous = if edited, do: nil, else: previous_order(previous)

      with {:ok, order} <-
             PositionOrder.evaluate(
               sample,
               order_previous,
               policy.movement_policy.order_policy,
               now,
               options
             ) do
        %{
          previous: previous,
          sample: sample,
          policy: policy,
          mode: mode,
          now: now,
          order: order,
          edited: edited,
          options: options
        }
        |> apply_order()
        |> wrap_result()
      end
    else
      false -> Admission.fail(:invalid_input)
      error -> error
    end
  end

  defp previous(nil, _), do: {:ok, nil}
  defp previous(state, options), do: validate_state(state, options)
  defp previous_order(nil), do: nil
  defp previous_order(state), do: state.order_sample
  defp wrap_result({:error, _} = error), do: error
  defp wrap_result(result), do: {:ok, result}

  defp scope(nil, _), do: :ok

  defp scope(previous, policy) do
    if previous.policy.id == policy.id,
      do: :ok,
      else: Admission.fail(:conflict)
  end

  defp edit_sample(nil, _, _), do: :ok

  defp edit_sample(previous, policy, sample) do
    if edited?(previous, policy) and sample.identity != previous.order_sample.identity and
         received_key(sample) < received_key(previous.last_received_sample),
       do: Admission.fail(:conflict),
       else: :ok
  end

  defp edited?(nil, _), do: false
  defp edited?(previous, policy), do: previous.policy.identity != policy.identity

  defp apply_order(%{order: %{"disposition" => "advance"}, edited: true} = context),
    do: revised(context)

  defp apply_order(%{order: %{"disposition" => "advance"}, previous: nil} = context),
    do: baseline(context, "initial_sample")

  defp apply_order(
         %{
           order: %{"disposition" => "advance"},
           previous: %{segment_sample: nil}
         } = context
       ),
       do: baseline(context, "segment_baseline_reestablished")

  defp apply_order(%{order: %{"disposition" => "advance"}} = context) do
    %{previous: previous, sample: sample, policy: policy, now: now, options: options} = context

    with {:ok, classification} <-
           PositionMovement.evaluate(
             previous.segment_sample,
             sample,
             policy.movement_policy,
             now,
             options
           ) do
      classify(Map.put(context, :classification, classification))
    end
  end

  defp apply_order(context), do: retained(context)

  defp baseline(context, reason) do
    %{
      previous: previous,
      sample: sample,
      policy: policy,
      mode: mode,
      order: order,
      options: options
    } =
      context

    segment_sample = if usable?(sample, policy), do: sample, else: nil

    with {:ok, next_state} <-
           state(
             state_values(
               policy,
               sample,
               sample,
               "accepted",
               segment_sample,
               "unknown",
               {nil, nil, nil},
               nil
             ),
             options
           ) do
      result(previous, next_state, order, nil, nil, mode, {"baseline", reason})
    end
  end

  defp revised(context) do
    %{
      previous: previous,
      sample: sample,
      policy: policy,
      mode: mode,
      order: order,
      options: options
    } =
      context

    segment_sample = if usable?(sample, policy), do: sample, else: nil

    with {:ok, next_state} <-
           state(
             state_values(
               policy,
               sample,
               sample,
               "accepted",
               segment_sample,
               "unknown",
               {nil, nil, nil},
               nil
             ),
             options
           ),
         {:ok, event} <- revision_event(previous, next_state, options) do
      result(previous, next_state, order, nil, event, mode, {"recomputed", "rule_revised"})
    end
  end

  defp classify(%{classification: %{"status" => "moving"}} = context),
    do: classified(context, "moving")

  defp classify(%{classification: %{"status" => "stationary"}} = context),
    do: classified(context, "stationary")

  defp classify(%{classification: %{"status" => "indeterminate"}} = context),
    do: unresolved(context, false)

  defp classify(context), do: unresolved(context, true)

  defp classified(context, class) do
    %{previous: previous, sample: sample, policy: policy, order: order} = context
    event_at = order["event_at"]

    cond do
      previous.motion_status == class ->
        build_classified(context, class, nil, nil, nil, previous.active_trip, nil, {
          "stable",
          class <> "_confirmed"
        })

      previous.candidate_status != class ->
        build_classified(
          context,
          previous.motion_status,
          class,
          event_at,
          sample,
          previous.active_trip,
          nil,
          {"pending", class <> "_dwell_started"}
        )

      event_at - previous.candidate_since < dwell(policy, class) ->
        build_classified(
          context,
          previous.motion_status,
          class,
          previous.candidate_since,
          previous.candidate_sample,
          previous.active_trip,
          nil,
          {"pending", class <> "_dwell_pending"}
        )

      class == "moving" ->
        with {:ok, trip} <-
               trip(policy, previous.candidate_sample, sample, context.options),
             {:ok, event} <- trip_started_event(policy, trip, context.options) do
          build_classified(context, "moving", nil, nil, nil, trip, event, {
            "transition",
            "movement_dwell_met"
          })
        end

      previous.motion_status == "moving" ->
        with {:ok, event} <-
               trip_stopped_event(
                 policy,
                 previous.active_trip,
                 previous.candidate_sample,
                 sample,
                 context.options
               ) do
          build_classified(context, "stationary", nil, nil, nil, nil, event, {
            "transition",
            "stop_dwell_met"
          })
        end

      true ->
        build_classified(context, "stationary", nil, nil, nil, nil, nil, {
          "baseline",
          "stationary_dwell_met"
        })
    end
  end

  defp build_classified(
         context,
         motion_status,
         candidate_status,
         candidate_since,
         candidate_sample,
         active_trip,
         event,
         outcome
       ) do
    %{
      previous: previous,
      sample: sample,
      policy: policy,
      mode: mode,
      order: order,
      classification: classification,
      options: options
    } = context

    with {:ok, next_state} <-
           state(
             state_values(
               policy,
               sample,
               sample,
               "accepted",
               sample,
               motion_status,
               {candidate_status, candidate_since, candidate_sample},
               active_trip
             ),
             options
           ) do
      result(previous, next_state, order, classification, event, mode, outcome)
    end
  end

  defp unresolved(context, true) do
    %{
      previous: previous,
      sample: sample,
      policy: policy,
      mode: mode,
      order: order,
      classification: classification,
      options: options
    } = context

    segment_sample =
      if reusable_baseline?(classification, sample, policy), do: sample, else: nil

    with {:ok, event} <-
           interrupted_event(
             policy,
             previous.active_trip,
             previous.order_sample,
             sample,
             classification["reason"],
             options
           ),
         {:ok, next_state} <-
           state(
             state_values(
               policy,
               sample,
               sample,
               "accepted",
               segment_sample,
               "unknown",
               {nil, nil, nil},
               nil
             ),
             options
           ) do
      status = if event, do: "transition", else: classification["status"]

      result(previous, next_state, order, classification, event, mode, {
        status,
        classification["reason"]
      })
    end
  end

  defp unresolved(context, false) do
    %{
      previous: previous,
      sample: sample,
      policy: policy,
      mode: mode,
      order: order,
      classification: classification,
      options: options
    } = context

    with {:ok, next_state} <-
           state(
             state_values(
               policy,
               sample,
               sample,
               "accepted",
               sample,
               previous.motion_status,
               {nil, nil, nil},
               previous.active_trip
             ),
             options
           ) do
      result(previous, next_state, order, classification, nil, mode, {
        classification["status"],
        classification["reason"]
      })
    end
  end

  defp retained(context) do
    %{
      previous: previous,
      sample: sample,
      policy: policy,
      mode: mode,
      now: now,
      order: order,
      edited: edited,
      options: options
    } = context

    next_state =
      if not is_nil(previous) and not edited and received_admissible?(sample, policy, now) and
           received_key(sample) > received_key(previous.last_received_sample) do
        {:ok, updated} =
          state(
            state_values(
              policy,
              previous.order_sample,
              sample,
              order["status"],
              previous.segment_sample,
              previous.motion_status,
              {
                previous.candidate_status,
                previous.candidate_since,
                previous.candidate_sample
              },
              previous.active_trip
            ),
            options
          )

        updated
      else
        previous
      end

    result(previous, next_state, order, nil, nil, mode, {order["status"], order["reason"]})
  end

  defp result(previous, next_state, order, classification, event, mode, {status, reason}) do
    %{
      "schema" => "wtr.motion-transition.v1",
      "status" => status,
      "reason" => reason,
      "mode" => Atom.to_string(mode),
      "state" => next_state,
      "state_changed" => state_identity(previous) != state_identity(next_state),
      "motion_status" => if(next_state, do: next_state.motion_status, else: "unknown"),
      "candidate_status" => if(next_state, do: next_state.candidate_status, else: nil),
      "active_trip" => if(next_state, do: next_state.active_trip, else: nil),
      "order" => order,
      "classification" => classification,
      "event" => event,
      "physical_action_dispatch" => action_effect(mode, event)
    }
  end

  defp state(value, options) do
    with {:ok, limits} <- Limits.new(options),
         {:ok, identity} <- Admission.digest(state_map(value), Limits.json(limits)) do
      {:ok,
       %State{
         policy: value.policy,
         order_sample: value.order_sample,
         last_received_sample: value.received_sample,
         last_received_outcome: value.received_outcome,
         segment_sample: value.segment_sample,
         motion_status: value.motion_status,
         candidate_status: value.candidate_status,
         candidate_since: value.candidate_since,
         candidate_sample: value.candidate_sample,
         active_trip: value.active_trip,
         identity: identity
       }}
    end
  end

  defp state_values(
         policy,
         order_sample,
         received_sample,
         received_outcome,
         segment_sample,
         motion_status,
         {candidate_status, candidate_since, candidate_sample},
         active_trip
       ),
       do: %{
         policy: policy,
         order_sample: order_sample,
         received_sample: received_sample,
         received_outcome: received_outcome,
         segment_sample: segment_sample,
         motion_status: motion_status,
         candidate_status: candidate_status,
         candidate_since: candidate_since,
         candidate_sample: candidate_sample,
         active_trip: active_trip
       }

  defp state_map(value),
    do: %{
      "schema" => "wtr.motion-state.v1",
      "algorithm" => "consecutive-segment-dwell-v1",
      "policy_identity" => value.policy.identity,
      "order_sample_identity" => value.order_sample.identity,
      "last_received_sample_identity" => value.received_sample.identity,
      "last_received_outcome" => value.received_outcome,
      "segment_sample_identity" => sample_identity(value.segment_sample),
      "motion_status" => value.motion_status,
      "candidate_status" => value.candidate_status,
      "candidate_since" => value.candidate_since,
      "candidate_sample_identity" => sample_identity(value.candidate_sample),
      "active_trip" => trip_map(value.active_trip)
    }

  defp trip(policy, start_sample, confirmation_sample, options) do
    started_at = sample_event_at(start_sample, policy)
    confirmed_at = sample_event_at(confirmation_sample, policy)

    identity_input = %{
      "schema" => "wtr.trip-key.v1",
      "algorithm" => "consecutive-segment-dwell-v1",
      "rule_id" => policy.id,
      "policy_identity" => policy.identity,
      "start_sample_identity" => start_sample.identity,
      "confirmation_sample_identity" => confirmation_sample.identity,
      "started_at" => started_at,
      "confirmed_at" => confirmed_at
    }

    with true <- confirmed_at - started_at >= policy.minimum_movement_ms,
         {:ok, limits} <- Limits.new(options),
         {:ok, id} <- Admission.digest(identity_input, Limits.json(limits)) do
      {:ok,
       %Trip{
         id: id,
         policy_identity: policy.identity,
         started_at: identity_input["started_at"],
         confirmed_at: identity_input["confirmed_at"],
         start_sample: start_sample,
         confirmation_sample: confirmation_sample
       }}
    else
      false -> Admission.fail(:conflict)
      error -> error
    end
  end

  defp active_trip(nil, _policy, _options), do: {:ok, nil}

  defp active_trip(%Trip{} = value, policy, options) do
    with {:ok, start_sample} <- PositionSample.validate(value.start_sample, options),
         {:ok, confirmation_sample} <-
           PositionSample.validate(value.confirmation_sample, options),
         {:ok, admitted} <- trip(policy, start_sample, confirmation_sample, options),
         true <- admitted === value do
      {:ok, admitted}
    else
      false -> Admission.fail(:conflict)
      error -> error
    end
  end

  defp active_trip(_, _, _), do: Admission.fail(:invalid_input)

  defp trip_started_event(policy, trip, options) do
    event(
      policy,
      trip,
      trip.start_sample,
      trip.confirmation_sample,
      {trip.started_at, trip.confirmed_at},
      {"trip.started", "movement_dwell_met"},
      options
    )
  end

  defp trip_stopped_event(policy, trip, start_sample, confirmation_sample, options) do
    event(
      policy,
      trip,
      start_sample,
      confirmation_sample,
      {sample_event_at(start_sample, policy), sample_event_at(confirmation_sample, policy)},
      {"trip.stopped", "stop_dwell_met"},
      options
    )
  end

  defp interrupted_event(_policy, nil, _from, _to, _reason, _options), do: {:ok, nil}

  defp interrupted_event(policy, trip, from, to, reason, options) do
    event(
      policy,
      trip,
      from,
      to,
      {sample_event_at(from, policy), sample_event_at(to, policy)},
      {"trip.interrupted", reason},
      options
    )
  end

  defp revision_event(%{active_trip: nil}, _next_state, _options), do: {:ok, nil}

  defp revision_event(previous, next_state, options) do
    interrupted_event(
      next_state.policy,
      previous.active_trip,
      previous.order_sample,
      next_state.order_sample,
      "rule_revised",
      options
    )
  end

  defp event(policy, trip, from, to, {effective_at, confirmed_at}, {kind, reason}, options) do
    identity_input = %{
      "schema" => "wtr.trip-event-key.v1",
      "algorithm" => "consecutive-segment-dwell-v1",
      "rule_id" => policy.id,
      "policy_identity" => policy.identity,
      "kind" => kind,
      "reason" => reason,
      "trip_id" => trip.id,
      "from_sample_identity" => from.identity,
      "to_sample_identity" => to.identity,
      "effective_at" => effective_at,
      "confirmed_at" => confirmed_at
    }

    with {:ok, limits} <- Limits.new(options),
         {:ok, id} <- Admission.digest(identity_input, Limits.json(limits)) do
      {:ok,
       Map.merge(identity_input, %{
         "schema" => "wtr.trip-event.v1",
         "id" => id,
         "rule_revision" => policy.revision,
         "from_position_evidence_id" => from.position.evidence_id,
         "from_position_bundle_identity" => from.position.bundle_identity,
         "to_position_evidence_id" => to.position.evidence_id,
         "to_position_bundle_identity" => to.position.bundle_identity
       })}
    end
  end

  defp candidate(nil, nil, nil, _policy, _options), do: {:ok, nil, nil, nil}

  defp candidate(status, since, %PositionSample{} = sample, policy, options)
       when status in ~w(stationary moving) and is_integer(since) do
    with {:ok, sample} <- PositionSample.validate(sample, options),
         true <- sample_event_at(sample, policy) == since do
      {:ok, status, since, sample}
    else
      false -> Admission.fail(:conflict)
      error -> error
    end
  end

  defp candidate(_, _, _, _, _), do: Admission.fail(:invalid_input)

  defp candidate_pending?(nil, nil, _order_sample, _policy), do: true

  defp candidate_pending?(status, since, order_sample, policy) do
    elapsed = sample_event_at(order_sample, policy) - since
    elapsed >= 0 and elapsed < dwell(policy, status)
  end

  defp optional_sample(nil, _), do: {:ok, nil}
  defp optional_sample(sample, options), do: PositionSample.validate(sample, options)

  defp trip_matches_motion?(nil, status), do: status != "moving"
  defp trip_matches_motion?(%Trip{}, status), do: status == "moving"

  defp usable?(sample, policy) do
    claim = sample.position.claim

    claim["availability"] == "available" and claim["quality"] == "valid" and
      (policy.movement_policy.uncertainty == :coordinate_only or
         claim["accuracy_kind"] == "bound")
  end

  defp reusable_baseline?(classification, sample, policy),
    do:
      classification["status"] == "unknown" and
        classification["reason"] in ~w(time_gap_exceeded repeated_event_time) and
        usable?(sample, policy)

  defp dwell(policy, "moving"), do: policy.minimum_movement_ms
  defp dwell(policy, "stationary"), do: policy.minimum_stop_ms

  defp sample_event_at(sample, _policy) do
    claim = sample.position.claim

    if is_integer(claim["fix_at"]) and claim["fix_clock"] == "trusted" do
      claim["fix_at"]
    else
      claim["received_at"]
    end
  end

  defp sample_identity(nil), do: nil
  defp sample_identity(sample), do: sample.identity
  defp state_identity(nil), do: nil
  defp state_identity(state), do: state.identity
  defp trip_map(nil), do: nil

  defp trip_map(trip),
    do: %{
      "id" => trip.id,
      "policy_identity" => trip.policy_identity,
      "started_at" => trip.started_at,
      "confirmed_at" => trip.confirmed_at,
      "start_sample_identity" => trip.start_sample.identity,
      "confirmation_sample_identity" => trip.confirmation_sample.identity
    }

  defp action_effect(:replay, _), do: "prohibited"
  defp action_effect(:live, nil), do: "none"
  defp action_effect(:live, _), do: "separate_authorization_required"

  defp received_admissible?(sample, policy, now),
    do:
      sample.position.claim["received_at"] <=
        now + policy.movement_policy.order_policy.future_skew_ms

  defp received_key(sample),
    do: [
      sample.position.claim["received_at"],
      sample.position.evidence_id,
      sample.position.bundle_identity,
      sample.identity
    ]

  defp duration?(value), do: is_integer(value) and value in 1..604_800_000

  defp policy_map(input, movement_policy),
    do: %{
      "schema" => "wtr.motion-transition-policy.v1",
      "algorithm" => "consecutive-segment-dwell-v1",
      "id" => input.id,
      "revision" => input.revision,
      "movement_policy_identity" => movement_policy.identity,
      "minimum_movement_ms" => input.minimum_movement_ms,
      "minimum_stop_ms" => input.minimum_stop_ms,
      "single_segment_transition" => "prohibited",
      "gap_semantics" => "interrupt_active_trip",
      "event_idempotency" => "trip-event-key-v1"
    }
end
