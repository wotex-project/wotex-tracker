defmodule Wotex.Tracker.GeofenceTransition do
  @moduledoc """
  Pure geofence baseline, edit and entry/exit state transitions.

  Position ordering is delegated to an admitted `PositionOrder` policy. State
  retains separate ordering, last-received and last-valid samples so uncertain or
  historical evidence cannot silently replace canonical membership.
  """
  alias Wotex.Tracker.{Admission, Error, Geofence, Limits, PositionOrder, PositionSample}

  @fields ~w(id revision order_policy max_transition_gap_ms)a
  @serialized_policy_fields ~w(schema algorithm id revision order_policy order_policy_identity max_transition_gap_ms initial_membership uncertain_membership edit_semantics event_idempotency identity)
  @state_fields ~w(schema algorithm fence policy samples order_sample_identity last_received_sample_identity last_received_outcome last_valid_sample_identity last_valid_membership last_valid_event_at identity)
  @event_fields ~w(schema id algorithm rule_id previous_rule_identity rule_identity previous_fence_identity fence_identity kind reason from_status from_sample_identity to_status to_sample_identity event_at fence_id fence_revision rule_revision from_position_evidence_id from_position_bundle_identity to_position_evidence_id to_position_bundle_identity)
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

  @doc "Projects a validated geofence transition policy and ordering policy to closed native JSON."
  @spec to_map(term(), term()) :: {:ok, map()} | {:error, Error.t()}
  def to_map(policy, options \\ []) do
    with {:ok, policy} <- validate(policy, options),
         {:ok, order_policy} <- PositionOrder.to_map(policy.order_policy, options) do
      {:ok,
       policy
       |> policy_map(policy.order_policy)
       |> Map.put("order_policy", order_policy)
       |> Map.put("identity", policy.identity)}
    end
  end

  @doc "Restores and revalidates a geofence transition policy from closed native JSON."
  @spec from_map(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(document, options \\ []) do
    with true <- exact_fields?(document, @serialized_policy_fields),
         true <-
           document["schema"] == "wtr.geofence-transition-policy.v1" and
             document["algorithm"] == "ordered-geofence-state-v1" and
             document["initial_membership"] == "baseline" and
             document["uncertain_membership"] == "retain_last_valid" and
             document["edit_semantics"] == "recompute_without_entry_or_exit" and
             document["event_idempotency"] == "geofence-transition-idempotency-v1",
         {:ok, order_policy} <- PositionOrder.from_map(document["order_policy"], options),
         true <- order_policy.identity == document["order_policy_identity"],
         {:ok, policy} <-
           new(
             %{
               id: document["id"],
               revision: document["revision"],
               order_policy: order_policy,
               max_transition_gap_ms: document["max_transition_gap_ms"]
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

  @doc "Projects validated geofence state with a deduplicated complete sample registry."
  @spec state_to_map(term(), term()) :: {:ok, map()} | {:error, Error.t()}
  def state_to_map(state, options \\ []) do
    with {:ok, state} <- validate_state(state, options),
         {:ok, fence} <- Geofence.to_map(state.fence, options),
         {:ok, policy} <- to_map(state.policy, options),
         {:ok, samples} <- sample_documents(state, options) do
      {:ok,
       %{
         "schema" => "wtr.geofence-state.v1",
         "algorithm" => "ordered-geofence-state-v1",
         "fence" => fence,
         "policy" => policy,
         "samples" => samples,
         "order_sample_identity" => state.order_sample.identity,
         "last_received_sample_identity" => state.last_received_sample.identity,
         "last_received_outcome" => state.last_received_outcome,
         "last_valid_sample_identity" => sample_identity(state.last_valid_sample),
         "last_valid_membership" => state.last_valid_membership,
         "last_valid_event_at" => state.last_valid_event_at,
         "identity" => state.identity
       }}
    end
  end

  @doc "Restores and revalidates geofence state from closed native JSON."
  @spec state_from_map(term(), term()) :: {:ok, State.t()} | {:error, Error.t()}
  def state_from_map(document, options \\ []) do
    with true <- exact_fields?(document, @state_fields),
         true <-
           document["schema"] == "wtr.geofence-state.v1" and
             document["algorithm"] == "ordered-geofence-state-v1",
         {:ok, fence} <- Geofence.from_map(document["fence"], options),
         {:ok, policy} <- from_map(document["policy"], options),
         {:ok, samples} <- restore_samples(document["samples"], options),
         {:ok, order_sample} <- fetch_sample(samples, document["order_sample_identity"]),
         {:ok, received_sample} <-
           fetch_sample(samples, document["last_received_sample_identity"]),
         {:ok, valid_sample} <-
           optional_restored_sample(samples, document["last_valid_sample_identity"]),
         {:ok, state} <-
           state(
             state_values(
               fence,
               policy,
               order_sample,
               received_sample,
               document["last_received_outcome"],
               valid_sample,
               document["last_valid_membership"],
               document["last_valid_event_at"]
             ),
             options
           ),
         true <- state.identity == document["identity"],
         {:ok, state} <- validate_state(state, options),
         {:ok, admitted} <- state_to_map(state, options),
         true <- admitted === document do
      {:ok, state}
    else
      false -> Admission.fail(:conflict)
      error -> error
    end
  end

  @doc "Re-evaluates a changed transition and rejects altered state, event or effect fields."
  @spec validate_transition(term(), term(), term()) :: {:ok, map()} | {:error, Error.t()}
  def validate_transition(previous, result, options \\ []) do
    with {:ok, previous} <- previous(previous, options),
         true <- is_map(result) and not is_struct(result),
         true <- result["schema"] == "wtr.geofence-transition.v1" and result["state_changed"],
         %State{} = next_state <- result["state"],
         {:ok, next_state} <- validate_state(next_state, options),
         {:ok, mode} <- mode_atom(result["mode"]),
         true <- is_integer(result["evaluated_at"]),
         {:ok, expected} <-
           evaluate(
             previous,
             next_state.fence,
             next_state.last_received_sample,
             next_state.policy,
             mode,
             result["evaluated_at"],
             options
           ),
         true <- expected === result,
         :ok <- validate_optional_event(result["event"], options) do
      {:ok, result}
    else
      false -> Admission.fail(:conflict)
      error -> error
    end
  end

  @doc "Revalidates a stable geofence event and its content identity."
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
      now: now,
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
        edited_result(previous, next_state, order, membership, mode, now, options)
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
          now,
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
      now: now,
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
            now,
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
            now,
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
            now,
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
            now,
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
            now,
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
      now,
      {order["status"], order["reason"], false}
    )
  end

  defp edited_result(previous, next_state, order, membership, mode, now, options) do
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
          now,
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
        now,
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
         now,
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
      "physical_action_dispatch" => action_effect(mode, event),
      "evaluated_at" => now
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

  defp sample_documents(state, options) do
    [state.order_sample, state.last_received_sample, state.last_valid_sample]
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce_while({:ok, %{}}, &serialize_sample(&1, &2, options))
    |> then(fn
      {:ok, documents} ->
        {:ok, documents |> Map.values() |> Enum.sort_by(& &1["identity"])}

      error ->
        error
    end)
  end

  defp serialize_sample(sample, {:ok, documents}, options) do
    case PositionSample.to_map(sample, options) do
      {:ok, document} -> insert_sample_document(documents, sample.identity, document)
      error -> {:halt, error}
    end
  end

  defp insert_sample_document(documents, identity, document) do
    case Map.fetch(documents, identity) do
      :error -> {:cont, {:ok, Map.put(documents, identity, document)}}
      {:ok, ^document} -> {:cont, {:ok, documents}}
      {:ok, _other} -> {:halt, Admission.fail(:conflict)}
    end
  end

  defp restore_samples(documents, options) when is_list(documents) and length(documents) <= 3 do
    Enum.reduce_while(documents, {:ok, %{}}, &restore_sample(&1, &2, options))
  end

  defp restore_samples(_, _), do: Admission.fail(:invalid_input)

  defp restore_sample(document, {:ok, samples}, options) do
    case PositionSample.from_map(document, options) do
      {:ok, sample} -> restore_unique_sample(samples, sample)
      error -> {:halt, error}
    end
  end

  defp restore_unique_sample(samples, sample) do
    if Map.has_key?(samples, sample.identity),
      do: {:halt, Admission.fail(:conflict)},
      else: {:cont, {:ok, Map.put(samples, sample.identity, sample)}}
  end

  defp fetch_sample(samples, identity) when is_binary(identity) do
    case Map.fetch(samples, identity) do
      {:ok, sample} -> {:ok, sample}
      :error -> Admission.fail(:dangling_reference)
    end
  end

  defp fetch_sample(_, _), do: Admission.fail(:invalid_input)
  defp optional_restored_sample(_samples, nil), do: {:ok, nil}
  defp optional_restored_sample(samples, identity), do: fetch_sample(samples, identity)

  defp sample_identity(nil), do: nil
  defp sample_identity(sample), do: sample.identity

  defp validate_optional_event(nil, _options), do: :ok
  defp validate_optional_event(event, options), do: validate_event(event, options)

  defp event_shape?(event, limits) do
    ids =
      ~w(id rule_id previous_rule_identity rule_identity previous_fence_identity fence_identity reason from_sample_identity to_sample_identity fence_id fence_revision rule_revision from_position_evidence_id from_position_bundle_identity to_position_evidence_id to_position_bundle_identity)

    event["schema"] == "wtr.geofence-event.v1" and
      event["algorithm"] == "geofence-transition-idempotency-v1" and
      Admission.each(Enum.map(ids, &event[&1]), &Admission.id(&1, limits)) == :ok and
      event["kind"] in ~w(geofence.entered geofence.exited geofence.recomputed) and
      event["from_status"] in ~w(inside outside) and event["to_status"] in ~w(inside outside) and
      is_integer(event["event_at"])
  end

  defp event_key(event),
    do: %{
      "schema" => "wtr.geofence-event-key.v1",
      "algorithm" => event["algorithm"],
      "rule_id" => event["rule_id"],
      "previous_rule_identity" => event["previous_rule_identity"],
      "rule_identity" => event["rule_identity"],
      "previous_fence_identity" => event["previous_fence_identity"],
      "fence_identity" => event["fence_identity"],
      "kind" => event["kind"],
      "reason" => event["reason"],
      "from_status" => event["from_status"],
      "from_sample_identity" => event["from_sample_identity"],
      "to_status" => event["to_status"],
      "to_sample_identity" => event["to_sample_identity"],
      "event_at" => event["event_at"]
    }

  defp mode_atom("live"), do: {:ok, :live}
  defp mode_atom("replay"), do: {:ok, :replay}
  defp mode_atom(_), do: Admission.fail(:invalid_input)

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

  defp exact_fields?(value, fields),
    do:
      is_map(value) and not is_struct(value) and
        Enum.sort(Map.keys(value)) == Enum.sort(fields)
end
