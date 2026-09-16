defmodule Wotex.Tracker.TripDistance do
  @moduledoc """
  Bounded deterministic distance reconstruction for an identified trip.

  Only adjacent segments proved moving by the nested movement policy contribute
  distance. Every other segment remains an explicit exclusion, and no exclusion
  is bridged by joining its surrounding positions.
  """

  alias Wotex.Tracker.{
    Admission,
    Error,
    Limits,
    MotionTransition,
    PositionMovement,
    PositionSample
  }

  @fields ~w(id revision motion_policy max_samples)a
  @type t :: %__MODULE__{}
  @enforce_keys @fields ++ [:identity]
  defstruct @enforce_keys

  @doc "Admits a motion policy and a hard bound for reconstructed samples."
  @spec new(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(input, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         :ok <- Admission.fields(input, @fields),
         :ok <- Admission.each([input.id, input.revision], &Admission.id(&1, limits)),
         {:ok, motion_policy} <- MotionTransition.validate(input.motion_policy, options),
         true <-
           is_integer(input.max_samples) and
             input.max_samples in 2..min(limits.max_collection_size, 4096),
         {:ok, identity} <-
           Admission.digest(policy_map(input, motion_policy), Limits.json(limits)) do
      {:ok,
       %__MODULE__{
         id: input.id,
         revision: input.revision,
         motion_policy: motion_policy,
         max_samples: input.max_samples,
         identity: identity
       }}
    else
      false -> Admission.fail(:invalid_input)
      error -> error
    end
  end

  @doc "Rejects modified nested policy, sample bound or content identity."
  @spec validate(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(value, options \\ [])

  def validate(%__MODULE__{} = policy, options) do
    with {:ok, admitted} <- new(Map.take(policy, @fields), options) do
      if admitted === policy, do: {:ok, admitted}, else: Admission.fail(:conflict)
    end
  end

  def validate(_, _), do: Admission.fail(:invalid_input)

  @doc "Reconstructs distance from a bounded, canonically ordered trip sample list."
  @spec evaluate(term(), term(), term(), term(), term()) :: {:ok, map()} | {:error, Error.t()}
  def evaluate(trip, samples, policy, now, options \\ []) do
    with {:ok, policy} <- validate(policy, options),
         {:ok, trip} <-
           MotionTransition.validate_trip(trip, policy.motion_policy, options),
         :ok <- Admission.bounded_list(samples, policy.max_samples),
         true <- length(samples) >= 2 and is_integer(now),
         {:ok, samples} <- samples(samples, options),
         :ok <- unique(samples),
         :ok <- trip_scope(trip, samples),
         {:ok, segments} <- classify_segments(samples, policy, now, options),
         {:ok, result} <- result(trip, samples, policy, segments, options) do
      {:ok, result}
    else
      false -> Admission.fail(:invalid_input)
      error -> error
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
      {:ok, admitted} -> {:ok, Enum.reverse(admitted)}
      error -> error
    end
  end

  defp unique(samples) do
    identities = Enum.map(samples, & &1.identity)

    if length(identities) == length(Enum.uniq(identities)),
      do: :ok,
      else: Admission.fail(:duplicate_id)
  end

  defp trip_scope(trip, [first | rest]) do
    confirmation_index =
      Enum.find_index(rest, &(&1.identity == trip.confirmation_sample.identity))

    if first.identity == trip.start_sample.identity and not is_nil(confirmation_index),
      do: :ok,
      else: Admission.fail(:conflict)
  end

  defp classify_segments(samples, policy, now, options) do
    samples
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce_while({:ok, []}, fn [from, to], {:ok, segments} ->
      case PositionMovement.evaluate(
             from,
             to,
             policy.motion_policy.movement_policy,
             now,
             options
           ) do
        {:ok, %{"order" => %{"disposition" => "advance"}} = classification} ->
          {:cont, {:ok, [segment(from, to, classification) | segments]}}

        {:ok, classification} ->
          {:halt, unordered(classification)}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, segments} -> {:ok, Enum.reverse(segments)}
      error -> error
    end
  end

  defp unordered(classification) do
    case classification["order"]["reason"] do
      "same_sample" -> Admission.fail(:duplicate_id)
      _ -> Admission.fail(:conflict)
    end
  end

  defp segment(from, to, classification) do
    included = classification["status"] == "moving"

    %{
      "schema" => "wtr.trip-distance-segment.v1",
      "from_sample_identity" => from.identity,
      "from_position_evidence_id" => from.position.evidence_id,
      "from_position_bundle_identity" => from.position.bundle_identity,
      "to_sample_identity" => to.identity,
      "to_position_evidence_id" => to.position.evidence_id,
      "to_position_bundle_identity" => to.position.bundle_identity,
      "event_at" => classification["order"]["event_at"],
      "status" => classification["status"],
      "reason" => classification["reason"],
      "included" => included,
      "center_distance_m" => if(included, do: classification["center_distance_m"], else: nil),
      "lower_distance_m" => if(included, do: classification["lower_distance_m"], else: nil),
      "upper_distance_m" => if(included, do: classification["upper_distance_m"], else: nil)
    }
  end

  defp result(trip, samples, policy, segments, options) do
    included = Enum.filter(segments, & &1["included"])
    excluded = length(segments) - length(included)

    value = %{
      "schema" => "wtr.trip-distance.v1",
      "algorithm" => "ordered-moving-segment-sum-v1",
      "status" => if(excluded == 0, do: "complete", else: "partial"),
      "reason" => if(excluded == 0, do: "all_segments_included", else: "segments_excluded"),
      "trip_id" => trip.id,
      "trip_started_at" => trip.started_at,
      "trip_confirmed_at" => trip.confirmed_at,
      "start_sample_identity" => hd(samples).identity,
      "end_sample_identity" => List.last(samples).identity,
      "sample_count" => length(samples),
      "included_segment_count" => length(included),
      "excluded_segment_count" => excluded,
      "center_distance_m" => sum(included, "center_distance_m"),
      "lower_distance_m" => sum(included, "lower_distance_m"),
      "upper_distance_m" => sum(included, "upper_distance_m"),
      "segments" => segments,
      "policy_revision" => policy.revision,
      "policy_identity" => policy.identity
    }

    with {:ok, limits} <- Limits.new(options),
         {:ok, identity} <- Admission.digest(value, Limits.json(limits)) do
      {:ok, Map.put(value, "identity", identity)}
    end
  end

  defp sum(segments, key), do: Enum.reduce(segments, 0.0, &(&1[key] + &2))

  defp policy_map(input, motion_policy),
    do: %{
      "schema" => "wtr.trip-distance-policy.v1",
      "algorithm" => "ordered-moving-segment-sum-v1",
      "id" => input.id,
      "revision" => input.revision,
      "motion_policy_identity" => motion_policy.identity,
      "max_samples" => input.max_samples,
      "included_status" => "moving",
      "excluded_segment_bridge" => "prohibited"
    }
end
