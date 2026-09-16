defmodule Wotex.Tracker.GeofenceCrossing do
  @moduledoc """
  Bounded straight-segment crossing inference between two outside positions.

  The result is an interpolation claim over identified endpoints, not evidence of
  the actual route or a fabricated crossing timestamp. Time and distance gaps are
  explicit content-bound policy.
  """

  alias Wotex.Tracker.{
    Admission,
    Error,
    Geofence,
    Limits,
    PositionOrder,
    PositionSample
  }

  @fields ~w(id revision order_policy max_gap_ms max_distance_m)a
  @serialized_fields ~w(schema algorithm id revision order_policy order_policy_identity max_gap_ms max_distance_m required_endpoint_membership boundary_touch crossing_time identity)
  @event_fields ~w(schema id algorithm rule_id rule_identity fence_identity kind from_sample_identity to_sample_identity from_event_at to_event_at time_gap_ms endpoint_distance_m geometry_algorithm fence_id fence_revision rule_revision from_position_evidence_id from_position_bundle_identity to_position_evidence_id to_position_bundle_identity route_claim crossing_time)
  @type t :: %__MODULE__{}
  @enforce_keys @fields ++ [:identity]
  defstruct @enforce_keys

  @doc "Admits ordering plus finite time and distance gaps for segment interpolation."
  @spec new(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(input, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         :ok <- Admission.fields(input, @fields),
         :ok <- Admission.each([input.id, input.revision], &Admission.id(&1, limits)),
         {:ok, order_policy} <- PositionOrder.validate(input.order_policy, options),
         true <- is_integer(input.max_gap_ms) and input.max_gap_ms in 0..604_800_000,
         true <- number?(input.max_distance_m, 0, 1_000_000),
         {:ok, identity} <-
           Admission.digest(policy_map(input, order_policy), Limits.json(limits)) do
      {:ok,
       %__MODULE__{
         id: input.id,
         revision: input.revision,
         order_policy: order_policy,
         max_gap_ms: input.max_gap_ms,
         max_distance_m: input.max_distance_m,
         identity: identity
       }}
    else
      false -> Admission.fail(:invalid_input)
      error -> error
    end
  end

  @doc "Rejects changed rule, ordering policy, thresholds or identity."
  @spec validate(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(value, options \\ [])

  def validate(%__MODULE__{} = policy, options) do
    with {:ok, admitted} <- new(Map.take(policy, @fields), options) do
      if admitted === policy, do: {:ok, admitted}, else: Admission.fail(:conflict)
    end
  end

  def validate(_, _), do: Admission.fail(:invalid_input)

  @doc "Projects a validated crossing policy and nested ordering policy to closed native JSON."
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

  @doc "Restores and revalidates a crossing policy from closed native JSON."
  @spec from_map(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(document, options \\ []) do
    with true <- exact_fields?(document, @serialized_fields),
         true <-
           document["schema"] == "wtr.geofence-crossing-policy.v1" and
             document["algorithm"] == "bounded-straight-segment-crossing-v1" and
             document["required_endpoint_membership"] == "outside" and
             document["boundary_touch"] == "not_a_crossing" and
             document["crossing_time"] == "unknown",
         {:ok, order_policy} <- PositionOrder.from_map(document["order_policy"], options),
         true <- order_policy.identity == document["order_policy_identity"],
         {:ok, policy} <-
           new(
             %{
               id: document["id"],
               revision: document["revision"],
               order_policy: order_policy,
               max_gap_ms: document["max_gap_ms"],
               max_distance_m: document["max_distance_m"]
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

  @doc "Re-evaluates a crossing result and rejects altered event or effect fields."
  @spec validate_result(term(), term(), term(), term(), term(), term()) ::
          {:ok, map()} | {:error, Error.t()}
  def validate_result(fence, from, to, policy, result, options \\ []) do
    with {:ok, fence} <- Geofence.validate(fence, options),
         {:ok, from} <- PositionSample.validate(from, options),
         {:ok, to} <- PositionSample.validate(to, options),
         {:ok, policy} <- validate(policy, options),
         true <- is_map(result) and not is_struct(result),
         true <- result["schema"] == "wtr.geofence-crossing.v1",
         {:ok, mode} <- mode_atom(result["mode"]),
         true <- is_integer(result["evaluated_at"]),
         {:ok, expected} <-
           evaluate(fence, from, to, policy, mode, result["evaluated_at"], options),
         true <- expected === result,
         :ok <- validate_optional_event(result["event"], options) do
      {:ok, result}
    else
      false -> Admission.fail(:conflict)
      error -> error
    end
  end

  @doc "Revalidates a stable inferred-crossing event and its content identity."
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

  @doc "Infers a bounded crossing interval in explicit `:live` or `:replay` mode."
  @spec evaluate(term(), term(), term(), term(), term(), term(), term()) ::
          {:ok, map()} | {:error, Error.t()}
  def evaluate(fence, from, to, policy, mode, now, options \\ []) do
    with {:ok, fence} <- Geofence.validate(fence, options),
         {:ok, from} <- PositionSample.validate(from, options),
         {:ok, to} <- PositionSample.validate(to, options),
         {:ok, policy} <- validate(policy, options),
         true <- mode in [:live, :replay] and is_integer(now),
         {:ok, from_order} <-
           PositionOrder.evaluate(from, nil, policy.order_policy, now, options),
         {:ok, order} <- PositionOrder.evaluate(to, from, policy.order_policy, now, options) do
      classify(%{
        fence: fence,
        from: from,
        to: to,
        policy: policy,
        mode: mode,
        now: now,
        from_order: from_order,
        order: order,
        options: options
      })
    else
      false -> Admission.fail(:invalid_input)
      error -> error
    end
  end

  defp classify(context) do
    %{
      fence: fence,
      from: from,
      to: to,
      from_order: from_order,
      order: order,
      options: options
    } = context

    cond do
      from_order["disposition"] != "advance" ->
        {:ok, result(context, from_order, nil, nil, "unknown", from_order["reason"], nil)}

      order["disposition"] != "advance" ->
        {:ok, result(context, order, nil, nil, order["status"], order["reason"], nil)}

      true ->
        with {:ok, trace} <-
               Geofence.trace(
                 fence,
                 from.position,
                 from.bundle,
                 to.position,
                 to.bundle,
                 options
               ) do
          gap = order["event_at"] - from_order["event_at"]

          classify_trace(context, trace, gap)
        end
    end
  end

  defp classify_trace(context, trace, gap) do
    %{
      fence: fence,
      from: from,
      to: to,
      policy: policy,
      order: order,
      options: options
    } =
      context

    cond do
      gap > policy.max_gap_ms ->
        {:ok,
         result(
           context,
           order,
           trace,
           gap,
           "not_inferred",
           "time_gap_exceeded",
           nil
         )}

      trace["status"] == "unknown" ->
        {:ok, result(context, order, trace, gap, "unknown", trace["reason"], nil)}

      trace["status"] == "does_not_infer" ->
        {:ok, result(context, order, trace, gap, "not_applicable", trace["reason"], nil)}

      trace["endpoint_distance_m"] > policy.max_distance_m ->
        {:ok,
         result(
           context,
           order,
           trace,
           gap,
           "not_inferred",
           "distance_gap_exceeded",
           nil
         )}

      trace["status"] == "crosses" ->
        with {:ok, event} <- event(fence, from, to, policy, order, trace, gap, options) do
          {:ok,
           result(
             context,
             order,
             trace,
             gap,
             "inferred_crossing",
             "bounded_straight_segment",
             event
           )}
        end

      true ->
        {:ok, result(context, order, trace, gap, "no_crossing", trace["reason"], nil)}
    end
  end

  defp event(fence, from, to, policy, order, trace, gap, options) do
    identity_input = %{
      "schema" => "wtr.geofence-crossing-event-key.v1",
      "algorithm" => "bounded-straight-segment-crossing-v1",
      "rule_id" => policy.id,
      "rule_identity" => policy.identity,
      "fence_identity" => fence.identity,
      "kind" => "geofence.crossing_inferred",
      "from_sample_identity" => from.identity,
      "to_sample_identity" => to.identity,
      "from_event_at" => order["event_at"] - gap,
      "to_event_at" => order["event_at"],
      "time_gap_ms" => gap,
      "endpoint_distance_m" => trace["endpoint_distance_m"],
      "geometry_algorithm" => trace["algorithm"]
    }

    with {:ok, limits} <- Limits.new(options),
         {:ok, id} <- Admission.digest(identity_input, Limits.json(limits)) do
      {:ok,
       Map.merge(identity_input, %{
         "schema" => "wtr.geofence-crossing-event.v1",
         "id" => id,
         "fence_id" => fence.id,
         "fence_revision" => fence.revision,
         "rule_revision" => policy.revision,
         "from_position_evidence_id" => from.position.evidence_id,
         "from_position_bundle_identity" => from.position.bundle_identity,
         "to_position_evidence_id" => to.position.evidence_id,
         "to_position_bundle_identity" => to.position.bundle_identity,
         "route_claim" => "straight_segment_interpolation_only",
         "crossing_time" => nil
       })}
    end
  end

  defp result(context, order, trace, gap, status, reason, event) do
    %{policy: policy, mode: mode, now: now} = context

    %{
      "schema" => "wtr.geofence-crossing.v1",
      "status" => status,
      "reason" => reason,
      "mode" => Atom.to_string(mode),
      "order" => order,
      "trace" => trace,
      "time_gap_ms" => gap,
      "event" => event,
      "policy_revision" => policy.revision,
      "policy_identity" => policy.identity,
      "physical_action_dispatch" => action_effect(mode, event),
      "evaluated_at" => now
    }
  end

  defp action_effect(:replay, _), do: "prohibited"
  defp action_effect(:live, nil), do: "none"
  defp action_effect(:live, _), do: "separate_authorization_required"

  defp number?(value, lower, upper),
    do: is_number(value) and value >= lower and value <= upper

  defp validate_optional_event(nil, _options), do: :ok
  defp validate_optional_event(event, options), do: validate_event(event, options)

  defp event_shape?(event, limits) do
    ids =
      ~w(id rule_id rule_identity fence_identity from_sample_identity to_sample_identity geometry_algorithm fence_id fence_revision rule_revision from_position_evidence_id from_position_bundle_identity to_position_evidence_id to_position_bundle_identity)

    event["schema"] == "wtr.geofence-crossing-event.v1" and
      event["algorithm"] == "bounded-straight-segment-crossing-v1" and
      Admission.each(Enum.map(ids, &event[&1]), &Admission.id(&1, limits)) == :ok and
      event_interval_shape?(event) and event_route_shape?(event)
  end

  defp event_interval_shape?(event),
    do:
      event["kind"] == "geofence.crossing_inferred" and
        is_integer(event["from_event_at"]) and is_integer(event["to_event_at"]) and
        is_integer(event["time_gap_ms"]) and event["time_gap_ms"] >= 0 and
        event["to_event_at"] - event["from_event_at"] == event["time_gap_ms"]

  defp event_route_shape?(event),
    do:
      number?(event["endpoint_distance_m"], 0, 1_000_000) and
        event["route_claim"] == "straight_segment_interpolation_only" and
        is_nil(event["crossing_time"])

  defp event_key(event),
    do: %{
      "schema" => "wtr.geofence-crossing-event-key.v1",
      "algorithm" => event["algorithm"],
      "rule_id" => event["rule_id"],
      "rule_identity" => event["rule_identity"],
      "fence_identity" => event["fence_identity"],
      "kind" => event["kind"],
      "from_sample_identity" => event["from_sample_identity"],
      "to_sample_identity" => event["to_sample_identity"],
      "from_event_at" => event["from_event_at"],
      "to_event_at" => event["to_event_at"],
      "time_gap_ms" => event["time_gap_ms"],
      "endpoint_distance_m" => event["endpoint_distance_m"],
      "geometry_algorithm" => event["geometry_algorithm"]
    }

  defp mode_atom("live"), do: {:ok, :live}
  defp mode_atom("replay"), do: {:ok, :replay}
  defp mode_atom(_), do: Admission.fail(:invalid_input)

  defp policy_map(input, order_policy),
    do: %{
      "schema" => "wtr.geofence-crossing-policy.v1",
      "algorithm" => "bounded-straight-segment-crossing-v1",
      "id" => input.id,
      "revision" => input.revision,
      "order_policy_identity" => order_policy.identity,
      "max_gap_ms" => input.max_gap_ms,
      "max_distance_m" => input.max_distance_m,
      "required_endpoint_membership" => "outside",
      "boundary_touch" => "not_a_crossing",
      "crossing_time" => "unknown"
    }

  defp exact_fields?(value, fields),
    do:
      is_map(value) and not is_struct(value) and
        Enum.sort(Map.keys(value)) == Enum.sort(fields)
end
