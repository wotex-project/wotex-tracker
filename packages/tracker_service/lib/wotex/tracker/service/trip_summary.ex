defmodule Wotex.Tracker.Service.TripSummary do
  @moduledoc false

  alias Wotex.Tracker.{
    Evidence,
    EvidenceBundle,
    MotionTransition,
    Observation,
    Position,
    PositionSample,
    TripDistance
  }

  alias Wotex.Tracker.Service.{Codec, Store}

  @maximum_samples 100

  def run(service, access, thing, trip, now) do
    with {:ok, input} <-
           Store.authorized_trip_summary_input(service.store, access, thing, trip, now),
         {:ok, state} <- restore_state(input["start_state"]),
         true <- state.active_trip.id == trip,
         {:ok, samples} <- samples(input["inputs"]),
         {:ok, policy} <- policy(state, input["started"]),
         {:ok, summary} <-
           evaluate(state.active_trip, samples, policy, input["terminal_created_at"]),
         {:ok, public} <- project(thing, input, summary) do
      {:ok, public}
    else
      false -> {:error, :storage_unavailable}
      error -> error
    end
  end

  defp restore_state(document) do
    case MotionTransition.state_from_map(document) do
      {:ok, %{active_trip: %MotionTransition.Trip{}} = state} -> {:ok, state}
      _ -> {:error, :storage_unavailable}
    end
  end

  defp samples(inputs) do
    Enum.reduce_while(inputs, {:ok, []}, fn input, {:ok, samples} ->
      case sample(input) do
        {:ok, sample} -> {:cont, {:ok, [sample | samples]}}
        error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, samples} -> {:ok, Enum.reverse(samples)}
      error -> error
    end)
  end

  defp sample(%{"observation" => observation, "evidence" => %{"claims" => claims}})
       when is_list(claims) do
    with {:ok, observation} <- stored(Observation.from_map(observation)),
         {:ok, evidence} <- evidence(claims),
         {:ok, bundle} <- stored(EvidenceBundle.new([observation], evidence)),
         [position] <- Enum.filter(evidence, &(&1.kind == :position)),
         {:ok, position} <- stored(Position.new(position.id, bundle)),
         {:ok, sample} <- stored(PositionSample.new(position, bundle)) do
      {:ok, sample}
    else
      positions when is_list(positions) -> {:error, :unavailable}
      error -> error
    end
  end

  defp sample(_), do: {:error, :storage_unavailable}

  defp evidence(claims) do
    Enum.reduce_while(claims, {:ok, []}, fn claim, {:ok, evidence} ->
      case Evidence.from_map(claim) do
        {:ok, value} -> {:cont, {:ok, [value | evidence]}}
        _ -> {:halt, {:error, :storage_unavailable}}
      end
    end)
    |> then(fn
      {:ok, evidence} -> {:ok, Enum.reverse(evidence)}
      error -> error
    end)
  end

  defp stored({:ok, value}), do: {:ok, value}
  defp stored(_), do: {:error, :storage_unavailable}

  defp policy(state, started) do
    TripDistance.new(%{
      id: "retained-trip-distance",
      revision: started["rule_revision"],
      motion_policy: state.policy,
      max_samples: @maximum_samples
    })
    |> stored()
  end

  defp evaluate(trip, samples, policy, now) do
    case TripDistance.evaluate(trip, samples, policy, now) do
      {:ok, summary} -> {:ok, summary}
      {:error, %{code: code}} when code in [:conflict, :duplicate_id] -> {:error, :unavailable}
      _ -> {:error, :storage_unavailable}
    end
  end

  defp project(thing, input, summary) do
    terminal = input["terminal"]

    material = %{
      "schema" => "wtr.trip-summary.v1",
      "algorithm" => summary["algorithm"],
      "thing_id" => thing,
      "trip_id" => summary["trip_id"],
      "snapshot_generation" => input["generation"],
      "terminal_kind" => terminal["kind"],
      "terminal_reason" => terminal["reason"],
      "started_at" => summary["trip_started_at"],
      "confirmed_moving_at" => summary["trip_confirmed_at"],
      "ended_at" => terminal["effective_at"],
      "confirmed_ended_at" => terminal["confirmed_at"],
      "status" => summary["status"],
      "reason" => summary["reason"],
      "sample_count" => summary["sample_count"],
      "included_segment_count" => summary["included_segment_count"],
      "excluded_segment_count" => summary["excluded_segment_count"],
      "center_distance_m" => summary["center_distance_m"],
      "lower_distance_m" => summary["lower_distance_m"],
      "upper_distance_m" => summary["upper_distance_m"],
      "segments" => Enum.map(summary["segments"], &public_segment/1),
      "rule_revision" => input["started"]["rule_revision"]
    }

    {:ok,
     Map.put(
       material,
       "identity",
       "wtr-trip-summary-v1:sha256:" <> Codec.digest(material)
     )}
  end

  defp public_segment(segment) do
    Map.take(
      segment,
      ~w(schema event_at status reason included center_distance_m lower_distance_m upper_distance_m)
    )
  end
end
