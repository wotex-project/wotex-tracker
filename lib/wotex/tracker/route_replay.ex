defmodule Wotex.Tracker.RouteReplay do
  @moduledoc """
  Bounded, gap-honest route projection over admitted position samples.

  Replay orders samples from their declared clocks, retains exact qualified
  coordinates and starts a new segment after every rejected sample or excessive
  time/distance gap. It does not infer a path, crossing time or missing point.
  """

  alias Wotex.Tracker.{Admission, Error, Limits, PositionSample}

  @fields ~w(id revision event_time qualities max_gap_ms max_gap_m max_samples)a
  @event_times ~w(trusted_fix trusted_fix_or_receiver)a
  @qualities ~w(valid suspect)a
  @earth_radius_m 6_371_008.8
  @maximum_gap_ms 2_678_400_000
  @maximum_gap_m 40_100_000

  @type t :: %__MODULE__{}
  @enforce_keys @fields ++ [:identity]
  defstruct @enforce_keys

  @doc "Admits the clock, quality, gap and page bounds for one route projection."
  @spec new(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(input, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         :ok <- Admission.fields(input, @fields),
         :ok <- Admission.each([input.id, input.revision], &Admission.id(&1, limits)),
         true <- input.event_time in @event_times,
         :ok <- qualities(input.qualities),
         true <- integer_between?(input.max_gap_ms, 1, @maximum_gap_ms),
         true <- number_between?(input.max_gap_m, 0, @maximum_gap_m),
         true <-
           integer_between?(input.max_samples, 1, min(limits.max_collection_size, 1_000)),
         {:ok, identity} <- Admission.digest(policy_map(input), Limits.json(limits)) do
      {:ok, struct!(__MODULE__, Map.put(input, :identity, identity))}
    else
      false -> Admission.fail(:invalid_input)
      error -> error
    end
  end

  @doc "Rejects a changed replay policy or forged policy identity."
  @spec validate(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(value, options \\ [])

  def validate(%__MODULE__{} = policy, options) do
    with {:ok, admitted} <- new(Map.take(policy, @fields), options) do
      if admitted === policy, do: {:ok, admitted}, else: Admission.fail(:conflict)
    end
  end

  def validate(_, _), do: Admission.fail(:invalid_input)

  @doc "Projects an unordered bounded sample set into exact points, breaks and rejections."
  @spec evaluate(term(), term(), term()) :: {:ok, map()} | {:error, Error.t()}
  def evaluate(samples, policy, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         {:ok, policy} <- validate(policy, options),
         :ok <- Admission.bounded_list(samples, policy.max_samples),
         {:ok, samples} <- samples(samples, options),
         :ok <- unique(samples),
         tokens = samples |> Enum.map(&token(&1, policy)) |> Enum.sort_by(& &1.order),
         projection = project(tokens, policy),
         value = result(projection, length(samples), policy),
         {:ok, identity} <- Admission.digest(value, Limits.json(limits)) do
      {:ok, Map.put(value, "identity", identity)}
    end
  end

  defp samples(values, options) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, admitted} ->
      case PositionSample.validate(value, options) do
        {:ok, sample} -> {:cont, {:ok, [sample | admitted]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, admitted} -> {:ok, admitted}
      error -> error
    end
  end

  defp unique(samples) do
    identities = Enum.map(samples, & &1.identity)

    if length(identities) == length(Enum.uniq(identities)),
      do: :ok,
      else: Admission.fail(:duplicate_id)
  end

  defp token(sample, policy) do
    claim = sample.position.claim
    received_at = claim["received_at"]

    case event_at(claim, policy.event_time) do
      {:ok, event_at, basis} ->
        qualified_token(sample, policy, event_at, basis)

      {:error, reason} ->
        rejected_token(sample, received_at, reason)
    end
  end

  defp qualified_token(sample, policy, event_at, basis) do
    claim = sample.position.claim
    order = order(event_at, sample)

    cond do
      claim["availability"] != "available" ->
        rejected_token(sample, order, "unavailable")

      claim["quality"] not in Enum.map(policy.qualities, &Atom.to_string/1) ->
        rejected_token(sample, order, "quality:" <> claim["quality"])

      true ->
        %{accepted: true, order: order, point: point(sample, event_at, basis)}
    end
  end

  defp rejected_token(sample, received_at, reason) when is_integer(received_at),
    do: rejected_token(sample, order(received_at, sample), reason)

  defp rejected_token(sample, order, reason) do
    %{
      accepted: false,
      order: order,
      rejection: %{
        "sample_identity" => sample.identity,
        "position_evidence_id" => sample.position.evidence_id,
        "position_bundle_identity" => sample.position.bundle_identity,
        "received_at" => sample.position.claim["received_at"],
        "reason" => reason
      }
    }
  end

  defp event_at(
         %{"fix_at" => fix_at, "fix_clock" => "trusted", "received_at" => received_at},
         _
       )
       when is_integer(fix_at) and fix_at <= received_at,
       do: {:ok, fix_at, "fix"}

  defp event_at(%{"fix_at" => fix_at, "received_at" => received_at}, _)
       when is_integer(fix_at) and fix_at > received_at,
       do: {:error, "fix_after_reception"}

  defp event_at(%{"fix_at" => nil, "received_at" => received_at}, :trusted_fix_or_receiver)
       when is_integer(received_at),
       do: {:ok, received_at, "receiver"}

  defp event_at(%{"fix_at" => nil}, :trusted_fix), do: {:error, "missing_fix_time"}
  defp event_at(_, _), do: {:error, "untrusted_fix_clock"}

  defp order(event_at, sample),
    do: {
      event_at,
      sample.position.claim["received_at"],
      sample.position.evidence_id,
      sample.position.bundle_identity,
      sample.identity
    }

  defp point(sample, event_at, basis) do
    claim = sample.position.claim

    %{
      "sample_identity" => sample.identity,
      "position_evidence_id" => sample.position.evidence_id,
      "position_bundle_identity" => sample.position.bundle_identity,
      "latitude" => claim["latitude"],
      "longitude" => claim["longitude"],
      "horizontal_accuracy_m" => claim["horizontal_accuracy_m"],
      "accuracy_kind" => claim["accuracy_kind"],
      "source" => claim["source"],
      "quality" => claim["quality"],
      "event_at" => event_at,
      "event_time_basis" => basis,
      "received_at" => claim["received_at"]
    }
  end

  defp project(tokens, policy) do
    initial = %{segments: [], current: [], breaks: [], rejected: [], prior: nil, pending: []}

    tokens
    |> Enum.reduce(initial, fn token, state -> project_token(token, state, policy) end)
    |> finish()
  end

  defp project_token(%{accepted: false, rejection: rejection}, state, _policy) do
    state
    |> close_segment()
    |> Map.update!(:rejected, &[rejection | &1])
    |> Map.update!(:pending, &[rejection["sample_identity"] | &1])
  end

  defp project_token(%{accepted: true, point: point}, %{prior: nil} = state, _policy),
    do: %{state | current: [point], prior: point, pending: []}

  defp project_token(%{accepted: true, point: point}, %{current: []} = state, _policy) do
    gap = replay_break(state.prior, point, "rejected_samples", state.pending)
    %{state | current: [point], breaks: [gap | state.breaks], prior: point, pending: []}
  end

  defp project_token(%{accepted: true, point: point}, state, policy) do
    case gap(state.prior, point, policy) do
      nil ->
        %{state | current: [point | state.current], prior: point}

      reason ->
        gap = replay_break(state.prior, point, reason, [])

        state
        |> close_segment()
        |> Map.put(:current, [point])
        |> Map.put(:prior, point)
        |> Map.update!(:breaks, &[gap | &1])
    end
  end

  defp close_segment(%{current: []} = state), do: state

  defp close_segment(state) do
    segment = %{
      "schema" => "wtr.route-segment.v1",
      "point_count" => length(state.current),
      "points" => Enum.reverse(state.current)
    }

    %{state | segments: [segment | state.segments], current: []}
  end

  defp finish(state) do
    state = close_segment(state)

    %{
      segments: Enum.reverse(state.segments),
      breaks: Enum.reverse(state.breaks),
      rejected: Enum.reverse(state.rejected)
    }
  end

  defp gap(from, to, policy) do
    gap_ms = to["event_at"] - from["event_at"]
    distance = distance(from, to)
    time? = gap_ms > policy.max_gap_ms
    distance? = distance > policy.max_gap_m

    case {time?, distance?} do
      {true, true} -> "time_and_distance_gap"
      {true, false} -> "time_gap"
      {false, true} -> "distance_gap"
      {false, false} -> nil
    end
  end

  defp replay_break(from, to, reason, rejected) do
    %{
      "schema" => "wtr.route-break.v1",
      "after_sample_identity" => from["sample_identity"],
      "before_sample_identity" => to["sample_identity"],
      "gap_ms" => to["event_at"] - from["event_at"],
      "center_distance_m" => distance(from, to),
      "reason" => reason,
      "rejected_sample_identities" => Enum.reverse(rejected)
    }
  end

  defp distance(from, to) do
    latitude_a = radians(from["latitude"])
    latitude_b = radians(to["latitude"])
    latitude_delta = latitude_b - latitude_a
    longitude_delta = radians(longitude_delta(from["longitude"], to["longitude"]))

    haversine =
      :math.pow(:math.sin(latitude_delta / 2), 2) +
        :math.cos(latitude_a) * :math.cos(latitude_b) *
          :math.pow(:math.sin(longitude_delta / 2), 2)

    @earth_radius_m * 2 * :math.asin(:math.sqrt(min(1.0, haversine)))
  end

  defp longitude_delta(from, to) do
    delta = to - from

    cond do
      delta > 180 -> delta - 360
      delta < -180 -> delta + 360
      true -> delta
    end
  end

  defp radians(value), do: value * :math.pi() / 180

  defp result(projection, sample_count, policy) do
    point_count = Enum.reduce(projection.segments, 0, &(&1["point_count"] + &2))
    partial = projection.breaks != [] or projection.rejected != []

    %{
      "schema" => "wtr.route-replay.v1",
      "algorithm" => "ordered-gap-honest-route-v1",
      "status" => status(point_count, partial),
      "reason" => reason(point_count, partial),
      "sample_count" => sample_count,
      "point_count" => point_count,
      "segment_count" => length(projection.segments),
      "break_count" => length(projection.breaks),
      "rejected_count" => length(projection.rejected),
      "segments" => projection.segments,
      "breaks" => projection.breaks,
      "rejected" => projection.rejected,
      "policy" => Map.put(policy_map(policy), "identity", policy.identity)
    }
  end

  defp status(0, _), do: "empty"
  defp status(_, true), do: "partial"
  defp status(_, false), do: "complete"
  defp reason(0, _), do: "no_qualified_positions"
  defp reason(_, true), do: "gaps_or_rejections"
  defp reason(_, false), do: "all_positions_qualified"

  defp qualities(values) do
    if is_list(values) and values != [] and length(values) == length(Enum.uniq(values)) and
         Enum.all?(values, &(&1 in @qualities)),
       do: :ok,
       else: Admission.fail(:invalid_input)
  end

  defp integer_between?(value, low, high),
    do: is_integer(value) and value >= low and value <= high

  defp number_between?(value, low, high),
    do: is_number(value) and value > low and value <= high

  defp policy_map(input),
    do: %{
      "schema" => "wtr.route-replay-policy.v1",
      "algorithm" => "ordered-gap-honest-route-v1",
      "id" => input.id,
      "revision" => input.revision,
      "event_time" => Atom.to_string(input.event_time),
      "qualities" => Enum.map(input.qualities, &Atom.to_string/1),
      "max_gap_ms" => input.max_gap_ms,
      "max_gap_m" => input.max_gap_m,
      "max_samples" => input.max_samples,
      "rejected_position_bridge" => "prohibited",
      "excessive_gap_bridge" => "prohibited"
    }
end
