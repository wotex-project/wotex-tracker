defmodule Wotex.Tracker.PositionMovement do
  @moduledoc """
  Deterministic movement classification over two ordered position samples.

  The classifier separates centreline distance from accuracy bounds and returns
  moving, stationary, indeterminate, implausible or reasoned unknown. It retains
  no state and does not turn one segment into a trip.
  """
  alias Wotex.Tracker.{Admission, Error, Limits, PositionOrder, PositionSample}

  @fields ~w(id revision order_policy moving_speed_m_s stationary_speed_m_s moving_distance_m stationary_distance_m max_plausible_speed_m_s max_gap_ms uncertainty)a
  @authalic_radius_m 6_371_007.180918475
  @type t :: %__MODULE__{}
  @enforce_keys @fields ++ [:identity]
  defstruct @enforce_keys

  @doc "Admits hysteresis, uncertainty, plausibility and event-gap policy."
  @spec new(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(input, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         :ok <- Admission.fields(input, @fields),
         :ok <- Admission.each([input.id, input.revision], &Admission.id(&1, limits)),
         {:ok, order_policy} <- PositionOrder.validate(input.order_policy, options),
         true <- thresholds?(input),
         {:ok, identity} <-
           Admission.digest(policy_map(input, order_policy), Limits.json(limits)) do
      {:ok,
       %__MODULE__{
         id: input.id,
         revision: input.revision,
         order_policy: order_policy,
         moving_speed_m_s: input.moving_speed_m_s,
         stationary_speed_m_s: input.stationary_speed_m_s,
         moving_distance_m: input.moving_distance_m,
         stationary_distance_m: input.stationary_distance_m,
         max_plausible_speed_m_s: input.max_plausible_speed_m_s,
         max_gap_ms: input.max_gap_ms,
         uncertainty: input.uncertainty,
         identity: identity
       }}
    else
      false -> Admission.fail(:invalid_input)
      error -> error
    end
  end

  @doc "Rejects modified thresholds, nested ordering policy or identity."
  @spec validate(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(value, options \\ [])

  def validate(%__MODULE__{} = policy, options) do
    with {:ok, admitted} <- new(Map.take(policy, @fields), options) do
      if admitted === policy, do: {:ok, admitted}, else: Admission.fail(:conflict)
    end
  end

  def validate(_, _), do: Admission.fail(:invalid_input)

  @doc "Classifies one ordered segment without retaining state or reading a clock."
  @spec evaluate(term(), term(), term(), term(), term()) :: {:ok, map()} | {:error, Error.t()}
  def evaluate(from, to, policy, now, options \\ []) do
    with {:ok, from} <- PositionSample.validate(from, options),
         {:ok, to} <- PositionSample.validate(to, options),
         {:ok, policy} <- validate(policy, options),
         true <- is_integer(now),
         {:ok, from_order} <-
           PositionOrder.evaluate(from, nil, policy.order_policy, now, options),
         {:ok, order} <- PositionOrder.evaluate(to, from, policy.order_policy, now, options) do
      {:ok, classify(from, to, policy, from_order, order)}
    else
      false -> Admission.fail(:invalid_input)
      error -> error
    end
  end

  defp classify(from, to, policy, from_order, order) do
    cond do
      from_order["disposition"] != "advance" ->
        result(from, to, policy, from_order, "unknown", from_order["reason"], nil)

      order["disposition"] != "advance" ->
        result(from, to, policy, order, order["status"], order["reason"], nil)

      true ->
        gap = order["event_at"] - from_order["event_at"]
        classify_positions(from, to, policy, order, gap)
    end
  end

  defp classify_positions(from, to, policy, order, gap) do
    from_claim = from.position.claim
    to_claim = to.position.claim

    cond do
      from_claim["availability"] != "available" or to_claim["availability"] != "available" ->
        result(from, to, policy, order, "unknown", "unavailable_endpoint", metrics(gap))

      from_claim["quality"] != "valid" or to_claim["quality"] != "valid" ->
        result(from, to, policy, order, "unknown", "suspect_endpoint", metrics(gap))

      gap > policy.max_gap_ms ->
        result(from, to, policy, order, "unknown", "time_gap_exceeded", metrics(gap))

      gap == 0 ->
        result(from, to, policy, order, "unknown", "repeated_event_time", metrics(gap))

      true ->
        distance = distance(from_claim, to_claim)
        classify_distance(from, to, policy, order, gap, distance)
    end
  end

  defp classify_distance(from, to, policy, order, gap, distance) do
    case bounds(from.position.claim, to.position.claim, policy, distance) do
      {:unknown, reason} ->
        result(from, to, policy, order, "unknown", reason, metrics(gap, distance))

      {:ok, lower, upper} ->
        lower_speed = lower * 1000 / gap
        upper_speed = upper * 1000 / gap
        values = metrics(gap, distance, lower, upper, lower_speed, upper_speed)

        cond do
          lower_speed > policy.max_plausible_speed_m_s ->
            result(from, to, policy, order, "implausible", "speed_limit_exceeded", values)

          lower_speed >= policy.moving_speed_m_s and lower >= policy.moving_distance_m ->
            result(from, to, policy, order, "moving", "movement_thresholds_met", values)

          upper_speed <= policy.stationary_speed_m_s and
              upper <= policy.stationary_distance_m ->
            result(from, to, policy, order, "stationary", "stationary_thresholds_met", values)

          true ->
            result(from, to, policy, order, "indeterminate", "hysteresis_or_uncertainty", values)
        end
    end
  end

  defp bounds(_from, _to, %{uncertainty: :coordinate_only}, distance),
    do: {:ok, distance, distance}

  defp bounds(from, to, %{uncertainty: :require_bound}, distance) do
    if from["accuracy_kind"] == "bound" and to["accuracy_kind"] == "bound" do
      uncertainty = from["horizontal_accuracy_m"] + to["horizontal_accuracy_m"]
      {:ok, max(distance - uncertainty, 0), distance + uncertainty}
    else
      {:unknown, "accuracy_bound_required"}
    end
  end

  defp result(from, to, policy, order, status, reason, values) do
    Map.merge(values || metrics(nil), %{
      "schema" => "wtr.position-movement.v1",
      "status" => status,
      "reason" => reason,
      "algorithm" => "wgs84-authalic-bounded-segment-v1",
      "order" => order,
      "from_sample_identity" => from.identity,
      "from_position_evidence_id" => from.position.evidence_id,
      "from_position_bundle_identity" => from.position.bundle_identity,
      "to_sample_identity" => to.identity,
      "to_position_evidence_id" => to.position.evidence_id,
      "to_position_bundle_identity" => to.position.bundle_identity,
      "policy_revision" => policy.revision,
      "policy_identity" => policy.identity,
      "uncertainty" => Atom.to_string(policy.uncertainty)
    })
  end

  defp metrics(
         gap,
         center \\ nil,
         lower \\ nil,
         upper \\ nil,
         lower_speed \\ nil,
         upper_speed \\ nil
       ),
       do: %{
         "time_gap_ms" => gap,
         "center_distance_m" => center,
         "lower_distance_m" => lower,
         "upper_distance_m" => upper,
         "lower_speed_m_s" => lower_speed,
         "upper_speed_m_s" => upper_speed
       }

  defp distance(from, to) do
    latitude1 = radians(from["latitude"])
    latitude2 = radians(to["latitude"])
    delta_latitude = latitude2 - latitude1
    delta_longitude = radians(to["longitude"] - from["longitude"])

    haversine =
      :math.sin(delta_latitude / 2) ** 2 +
        :math.cos(latitude1) * :math.cos(latitude2) * :math.sin(delta_longitude / 2) ** 2

    haversine = min(max(haversine, 0), 1)
    @authalic_radius_m * 2 * :math.atan2(:math.sqrt(haversine), :math.sqrt(max(1 - haversine, 0)))
  end

  defp thresholds?(input) do
    Enum.all?(
      [
        input.moving_speed_m_s,
        input.stationary_speed_m_s,
        input.moving_distance_m,
        input.stationary_distance_m,
        input.max_plausible_speed_m_s
      ],
      &number?(&1, 0, 1_000_000)
    ) and
      input.stationary_speed_m_s <= input.moving_speed_m_s and
      input.moving_speed_m_s <= input.max_plausible_speed_m_s and
      input.stationary_distance_m <= input.moving_distance_m and
      is_integer(input.max_gap_ms) and input.max_gap_ms in 0..604_800_000 and
      input.uncertainty in [:require_bound, :coordinate_only]
  end

  defp number?(value, lower, upper),
    do: is_number(value) and value >= lower and value <= upper

  defp radians(degrees), do: degrees * :math.pi() / 180

  defp policy_map(input, order_policy),
    do: %{
      "schema" => "wtr.position-movement-policy.v1",
      "algorithm" => "wgs84-authalic-bounded-segment-v1",
      "id" => input.id,
      "revision" => input.revision,
      "order_policy_identity" => order_policy.identity,
      "moving_speed_m_s" => input.moving_speed_m_s,
      "stationary_speed_m_s" => input.stationary_speed_m_s,
      "moving_distance_m" => input.moving_distance_m,
      "stationary_distance_m" => input.stationary_distance_m,
      "max_plausible_speed_m_s" => input.max_plausible_speed_m_s,
      "max_gap_ms" => input.max_gap_ms,
      "uncertainty" => Atom.to_string(input.uncertainty)
    }
end
