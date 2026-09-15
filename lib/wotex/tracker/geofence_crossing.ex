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
      classify(fence, from, to, policy, mode, from_order, order, options)
    else
      false -> Admission.fail(:invalid_input)
      error -> error
    end
  end

  defp classify(fence, from, to, policy, mode, from_order, order, options) do
    cond do
      from_order["disposition"] != "advance" ->
        {:ok, result(policy, mode, from_order, nil, nil, "unknown", from_order["reason"], nil)}

      order["disposition"] != "advance" ->
        {:ok, result(policy, mode, order, nil, nil, order["status"], order["reason"], nil)}

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

          classify_trace(
            %{
              fence: fence,
              from: from,
              to: to,
              policy: policy,
              mode: mode,
              order: order,
              options: options
            },
            trace,
            gap
          )
        end
    end
  end

  defp classify_trace(context, trace, gap) do
    %{
      fence: fence,
      from: from,
      to: to,
      policy: policy,
      mode: mode,
      order: order,
      options: options
    } =
      context

    cond do
      gap > policy.max_gap_ms ->
        {:ok, result(policy, mode, order, trace, gap, "not_inferred", "time_gap_exceeded", nil)}

      trace["status"] == "unknown" ->
        {:ok, result(policy, mode, order, trace, gap, "unknown", trace["reason"], nil)}

      trace["status"] == "does_not_infer" ->
        {:ok, result(policy, mode, order, trace, gap, "not_applicable", trace["reason"], nil)}

      trace["endpoint_distance_m"] > policy.max_distance_m ->
        {:ok,
         result(policy, mode, order, trace, gap, "not_inferred", "distance_gap_exceeded", nil)}

      trace["status"] == "crosses" ->
        with {:ok, event} <- event(fence, from, to, policy, order, trace, gap, options) do
          {:ok,
           result(
             policy,
             mode,
             order,
             trace,
             gap,
             "inferred_crossing",
             "bounded_straight_segment",
             event
           )}
        end

      true ->
        {:ok, result(policy, mode, order, trace, gap, "no_crossing", trace["reason"], nil)}
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

  defp result(policy, mode, order, trace, gap, status, reason, event) do
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
      "physical_action_dispatch" => action_effect(mode, event)
    }
  end

  defp action_effect(:replay, _), do: "prohibited"
  defp action_effect(:live, nil), do: "none"
  defp action_effect(:live, _), do: "separate_authorization_required"

  defp number?(value, lower, upper),
    do: is_number(value) and value >= lower and value <= upper

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
end
