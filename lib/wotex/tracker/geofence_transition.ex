defmodule Wotex.Tracker.GeofenceTransition do
  @moduledoc """
  Pure geofence baseline, edit and entry/exit state transitions.

  Position ordering is delegated to an admitted `PositionOrder` policy. State
  retains separate ordering, last-received and last-valid samples so uncertain or
  historical evidence cannot silently replace canonical membership.
  """
  alias Wotex.Tracker.{Admission, Error, Geofence, Limits, PositionOrder, PositionSample}

  @fields ~w(id revision order_policy max_transition_gap_ms)a
  @type t :: %__MODULE__{}
  @enforce_keys @fields ++ [:identity]
  defstruct @enforce_keys

  defmodule State do
    @moduledoc "Immutable geofence rule state returned by `GeofenceTransition.evaluate/7`."
    @type t :: %__MODULE__{}
    @enforce_keys [
      :fence,
      :policy,
      :order_sample,
      :last_received_sample,
      :last_received_outcome,
      :last_valid_sample,
      :last_valid_membership,
      :last_valid_event_at,
      :identity
    ]
    defstruct @enforce_keys
  end

  @doc "Admits a scoped rule, its complete ordering policy and maximum transition gap."
  @spec new(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(input, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         :ok <- Admission.fields(input, @fields),
         :ok <- Admission.each([input.id, input.revision], &Admission.id(&1, limits)),
         {:ok, order_policy} <- PositionOrder.validate(input.order_policy, options),
         true <-
           is_integer(input.max_transition_gap_ms) and
             input.max_transition_gap_ms in 0..604_800_000,
         {:ok, identity} <-
           Admission.digest(policy_map(input, order_policy), Limits.json(limits)) do
      {:ok,
       %__MODULE__{
         id: input.id,
         revision: input.revision,
         order_policy: order_policy,
         max_transition_gap_ms: input.max_transition_gap_ms,
         identity: identity
       }}
    else
      false -> Admission.fail(:invalid_input)
      error -> error
    end
  end

  @doc "Rejects modified rule or nested ordering-policy content."
  @spec validate(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(value, options \\ [])

  def validate(%__MODULE__{} = policy, options) do
    with {:ok, admitted} <- new(Map.take(policy, @fields), options) do
      if admitted === policy, do: {:ok, admitted}, else: Admission.fail(:conflict)
    end
  end

  def validate(_, _), do: Admission.fail(:invalid_input)

  @doc "Revalidates all state inputs, derived membership and its content identity."
  @spec validate_state(term(), term()) :: {:ok, State.t()} | {:error, Error.t()}
  def validate_state(value, options \\ [])

  def validate_state(%State{} = state, options) do
    with {:ok, fence} <- Geofence.validate(state.fence, options),
         {:ok, policy} <- validate(state.policy, options),
         {:ok, order_sample} <- PositionSample.validate(state.order_sample, options),
         {:ok, received_sample} <- PositionSample.validate(state.last_received_sample, options),
         true <- state.last_received_outcome in ~w(accepted duplicate historical unknown),
         {:ok, valid_sample, membership, event_at} <-
           valid_membership(
             state.last_valid_sample,
             state.last_valid_membership,
             state.last_valid_event_at,
             fence,
             policy,
             options
           ),
         {:ok, admitted} <-
           state(
             state_values(
               fence,
               policy,
               order_sample,
               received_sample,
               state.last_received_outcome,
               valid_sample,
               membership,
               event_at
             ),
             options
           ),
         true <- admitted === state do
      {:ok, admitted}
    else
      false -> Admission.fail(:conflict)
      error -> error
    end
  end

  def validate_state(_, _), do: Admission.fail(:invalid_input)

  @doc "Evaluates one admitted sample in explicit `:live` or `:replay` mode."
  @spec evaluate(term(), term(), term(), term(), term(), term(), term()) ::
          {:ok, map()} | {:error, Error.t()}
  def evaluate(previous, fence, sample, policy, mode, now, options \\ []) do
    with {:ok, previous} <- previous(previous, options),
         {:ok, fence} <- Geofence.validate(fence, options),
         {:ok, sample} <- PositionSample.validate(sample, options),
         {:ok, policy} <- validate(policy, options),
         true <- mode in [:live, :replay] and is_integer(now),
         :ok <- scope(previous, fence, policy),
         :ok <- edit_sample(previous, fence, policy, sample) do
      edited = edited?(previous, fence, policy)
      order_previous = if edited, do: nil, else: previous_order(previous)

      with {:ok, order} <-
             PositionOrder.evaluate(sample, order_previous, policy.order_policy, now, options) do
        %{
          previous: previous,
          fence: fence,
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
  defp wrap_result({:error, _} = error), do: error
  defp wrap_result(result), do: {:ok, result}
  defp previous_order(nil), do: nil
  defp previous_order(state), do: state.order_sample

  defp scope(nil, _, _), do: :ok

  defp scope(state, fence, policy) do
    if state.fence.id == fence.id and state.policy.id == policy.id,
      do: :ok,
      else: Admission.fail(:conflict)
  end

  defp edit_sample(nil, _, _, _), do: :ok

  defp edit_sample(state, fence, policy, sample) do
    if edited?(state, fence, policy) and sample.identity != state.order_sample.identity and
         received_key(sample) < received_key(state.last_received_sample),
       do: Admission.fail(:conflict),
       else: :ok
  end

  defp edited?(nil, _, _), do: false

  defp edited?(state, fence, policy),
    do: state.fence.identity != fence.identity or state.policy.identity != policy.identity

  defp apply_order(context) do
    %{fence: fence, sample: sample, order: order, options: options} = context

    if order["disposition"] == "advance" do
      with {:ok, membership} <- Geofence.evaluate(fence, sample.position, sample.bundle, options) do
        advance(Map.put(context, :membership, membership))
      end
    else
      retained(context)
    end
  end

  defp advance(%{edited: true} = context) do
    %{
      previous: previous,
      fence: fence,
      sample: sample,
      policy: policy,
      mode: mode,
      order: order,
      membership: membership,
      options: options
    } = context

    if known?(membership) do
      with {:ok, next_state} <-
             state(
               state_values(
                 fence,
                 policy,
                 sample,
                 sample,
                 "accepted",
                 sample,
                 membership,
                 order["event_at"]
               ),
               options
             ) do
        edited_result(previous, next_state, order, membership, mode, options)
      end
    else
      with {:ok, next_state} <-
             state(
               state_values(fence, policy, sample, sample, "accepted", nil, nil, nil),
               options
             ) do
        result(
          previous,
          next_state,
          order,
          membership,
          nil,
          mode,
          {membership["status"], "edit_recomputed_without_certain_membership", false}
        )
      end
    end
  end

  defp advance(context) do
    %{
      previous: previous,
      fence: fence,
      sample: sample,
      policy: policy,
      mode: mode,
      order: order,
      membership: membership,
      options: options
    } = context

    cond do
      not known?(membership) ->
        with {:ok, next_state} <-
               state(
                 state_values(
                   fence,
                   policy,
                   sample,
                   sample,
                   "accepted",
                   prior(previous, :last_valid_sample),
                   prior(previous, :last_valid_membership),
                   prior(previous, :last_valid_event_at)
                 ),
                 options
               ) do
          result(
            previous,
            next_state,
            order,
            membership,
            nil,
            mode,
            {membership["status"], membership["reason"], false}
          )
        end

      is_nil(previous) or is_nil(previous.last_valid_sample) ->
        with {:ok, next_state} <-
               known_state(fence, policy, sample, membership, order["event_at"], options) do
          result(
            previous,
            next_state,
            order,
            membership,
            nil,
            mode,
            {"baseline", "initial_membership", false}
          )
        end

      order["event_at"] - previous.last_valid_event_at > policy.max_transition_gap_ms ->
        with {:ok, next_state} <-
               known_state(fence, policy, sample, membership, order["event_at"], options) do
          result(
            previous,
            next_state,
            order,
            membership,
            nil,
            mode,
            {"baseline", "transition_gap_exceeded", false}
          )
        end

      membership["status"] == previous.last_valid_membership["status"] ->
        with {:ok, next_state} <-
               known_state(fence, policy, sample, membership, order["event_at"], options) do
          result(
            previous,
            next_state,
            order,
            membership,
            nil,
            mode,
            {"stable", "membership_unchanged", false}
          )
        end

      true ->
        with {:ok, next_state} <-
               known_state(fence, policy, sample, membership, order["event_at"], options),
             {:ok, event} <-
               event(
                 previous,
                 next_state,
                 transition_kind(membership),
                 "observed_membership_change",
                 options
               ) do
          result(
            previous,
            next_state,
            order,
            membership,
            event,
            mode,
            {"transition", "observed_membership_change", true}
          )
        end
    end
  end

  defp retained(context) do
    %{
      previous: previous,
      fence: fence,
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
              fence,
              policy,
              previous.order_sample,
              sample,
              order["status"],
              previous.last_valid_sample,
              previous.last_valid_membership,
              previous.last_valid_event_at
            ),
            options
          )

        updated
      else
        previous
      end

    result(
      previous,
      next_state,
      order,
      nil,
      nil,
      mode,
      {order["status"], order["reason"], false}
    )
  end

  defp edited_result(previous, next_state, order, membership, mode, options) do
    if previous && previous.last_valid_sample do
      reason = edit_reason(previous, next_state)

      with {:ok, event} <- event(previous, next_state, "geofence.recomputed", reason, options) do
        result(
          previous,
          next_state,
          order,
          membership,
          event,
          mode,
          {
            "recomputed",
            reason,
            previous.last_valid_membership["status"] != membership["status"]
          }
        )
      end
    else
      result(
        previous,
        next_state,
        order,
        membership,
        nil,
        mode,
        {"baseline", "initial_membership_after_edit", false}
      )
    end
  end

  defp known_state(fence, policy, sample, membership, event_at, options),
    do:
      state(
        state_values(
          fence,
          policy,
          sample,
          sample,
          "accepted",
          sample,
          membership,
          event_at
        ),
        options
      )

  defp valid_membership(nil, nil, nil, _fence, _policy, _options),
    do: {:ok, nil, nil, nil}

  defp valid_membership(sample, membership, event_at, fence, policy, options) do
    with {:ok, sample} <- PositionSample.validate(sample, options),
         {:ok, expected} <- Geofence.evaluate(fence, sample.position, sample.bundle, options),
         true <- expected === membership and known?(membership),
         true <- event_at === sample_event_at(sample, policy.order_policy) do
      {:ok, sample, membership, event_at}
    else
      false -> Admission.fail(:conflict)
      error -> error
    end
  end

  defp state(value, options) do
    with {:ok, limits} <- Limits.new(options),
         {:ok, identity} <-
           Admission.digest(state_map(value), Limits.json(limits)) do
      {:ok,
       %State{
         fence: value.fence,
         policy: value.policy,
         order_sample: value.order_sample,
         last_received_sample: value.received_sample,
         last_received_outcome: value.received_outcome,
         last_valid_sample: value.valid_sample,
         last_valid_membership: value.membership,
         last_valid_event_at: value.event_at,
         identity: identity
       }}
    end
  end

  defp state_values(
         fence,
         policy,
         order_sample,
         received_sample,
         received_outcome,
         valid_sample,
         membership,
         event_at
       ),
       do: %{
         fence: fence,
         policy: policy,
         order_sample: order_sample,
         received_sample: received_sample,
         received_outcome: received_outcome,
         valid_sample: valid_sample,
         membership: membership,
         event_at: event_at
       }

  defp state_map(value),
    do: %{
      "schema" => "wtr.geofence-state.v1",
      "algorithm" => "ordered-geofence-state-v1",
      "fence_identity" => value.fence.identity,
      "policy_identity" => value.policy.identity,
      "order_sample_identity" => value.order_sample.identity,
      "last_received_sample_identity" => value.received_sample.identity,
      "last_received_outcome" => value.received_outcome,
      "last_valid_sample_identity" =>
        if(value.valid_sample, do: value.valid_sample.identity, else: nil),
      "last_valid_membership" => value.membership,
      "last_valid_event_at" => value.event_at
    }

  defp event(previous, next_state, kind, reason, options) do
    from_membership = previous.last_valid_membership
    to_membership = next_state.last_valid_membership

    identity_input = %{
      "schema" => "wtr.geofence-event-key.v1",
      "algorithm" => "geofence-transition-idempotency-v1",
      "rule_id" => next_state.policy.id,
      "previous_rule_identity" => previous.policy.identity,
      "rule_identity" => next_state.policy.identity,
      "previous_fence_identity" => previous.fence.identity,
      "fence_identity" => next_state.fence.identity,
      "kind" => kind,
      "reason" => reason,
      "from_status" => from_membership["status"],
      "from_sample_identity" => previous.last_valid_sample.identity,
      "to_status" => to_membership["status"],
      "to_sample_identity" => next_state.last_valid_sample.identity,
      "event_at" => next_state.last_valid_event_at
    }

    with {:ok, limits} <- Limits.new(options),
         {:ok, id} <- Admission.digest(identity_input, Limits.json(limits)) do
      {:ok,
       Map.merge(identity_input, %{
         "schema" => "wtr.geofence-event.v1",
         "id" => id,
         "fence_id" => next_state.fence.id,
         "fence_revision" => next_state.fence.revision,
         "rule_revision" => next_state.policy.revision,
         "from_position_evidence_id" => previous.last_valid_sample.position.evidence_id,
         "from_position_bundle_identity" => previous.last_valid_sample.position.bundle_identity,
         "to_position_evidence_id" => next_state.last_valid_sample.position.evidence_id,
         "to_position_bundle_identity" => next_state.last_valid_sample.position.bundle_identity
       })}
    end
  end

  defp result(
         previous,
         next_state,
         order,
         membership,
         event,
         mode,
         {status, reason, membership_changed}
       ) do
    %{
      "schema" => "wtr.geofence-transition.v1",
      "status" => status,
      "reason" => reason,
      "mode" => Atom.to_string(mode),
      "state" => next_state,
      "state_changed" => state_identity(previous) != state_identity(next_state),
      "membership_changed" => membership_changed,
      "order" => order,
      "membership" => membership,
      "event" => event,
      "physical_action_dispatch" => action_effect(mode, event)
    }
  end

  defp state_identity(nil), do: nil
  defp state_identity(state), do: state.identity

  defp action_effect(:replay, _), do: "prohibited"
  defp action_effect(:live, nil), do: "none"
  defp action_effect(:live, _), do: "separate_authorization_required"

  defp known?(%{"status" => status}), do: status in ~w(inside outside)
  defp prior(nil, _), do: nil
  defp prior(state, field), do: Map.fetch!(state, field)

  defp transition_kind(%{"status" => "inside"}), do: "geofence.entered"
  defp transition_kind(%{"status" => "outside"}), do: "geofence.exited"

  defp edit_reason(previous, next_state) do
    case {
      previous.fence.identity != next_state.fence.identity,
      previous.policy.identity != next_state.policy.identity
    } do
      {true, true} -> "fence_and_rule_revised"
      {true, false} -> "fence_revised"
      {false, true} -> "rule_revised"
    end
  end

  defp received_admissible?(sample, policy, now),
    do: sample.position.claim["received_at"] <= now + policy.order_policy.future_skew_ms

  defp received_key(sample),
    do: [
      sample.position.claim["received_at"],
      sample.position.evidence_id,
      sample.position.bundle_identity,
      sample.identity
    ]

  defp sample_event_at(sample, order_policy) do
    claim = sample.position.claim

    cond do
      is_integer(claim["fix_at"]) and claim["fix_clock"] == "trusted" ->
        claim["fix_at"]

      is_nil(claim["fix_at"]) and order_policy.event_time == :trusted_fix_or_receiver ->
        claim["received_at"]

      true ->
        nil
    end
  end

  defp policy_map(input, order_policy),
    do: %{
      "schema" => "wtr.geofence-transition-policy.v1",
      "algorithm" => "ordered-geofence-state-v1",
      "id" => input.id,
      "revision" => input.revision,
      "order_policy_identity" => order_policy.identity,
      "max_transition_gap_ms" => input.max_transition_gap_ms,
      "initial_membership" => "baseline",
      "uncertain_membership" => "retain_last_valid",
      "edit_semantics" => "recompute_without_entry_or_exit",
      "event_idempotency" => "geofence-transition-idempotency-v1"
    }
end
