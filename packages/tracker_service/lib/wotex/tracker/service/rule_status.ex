defmodule Wotex.Tracker.Service.RuleStatus do
  @moduledoc false

  # Public rule inspection restores each committed document through its pure
  # constructor, then projects rule identity, status, timing and thresholds only.
  # Observations, evidence bundles, samples and coordinates stay private.

  alias Wotex.Tracker.{
    BatteryTransition,
    GeofenceTransition,
    HeartbeatTransition,
    MotionTransition,
    TransportDegradation
  }

  alias Wotex.Tracker.Service.Projection

  @restore %{
    "battery" => &BatteryTransition.state_from_map/1,
    "geofence" => &GeofenceTransition.state_from_map/1,
    "heartbeat" => &HeartbeatTransition.state_from_map/1,
    "motion" => &MotionTransition.state_from_map/1,
    "transport_degradation" => &TransportDegradation.state_from_map/1
  }

  def project(id, document) when is_binary(id) do
    with [kind, rule_id] <- String.split(id, ":", parts: 2),
         {:ok, restore} <- Map.fetch(@restore, kind),
         {:ok, state} <- restore.(document),
         true <- state.policy.id == rule_id do
      {:ok,
       Map.merge(
         %{
           "schema" => "wtr.rule-status.v1",
           "kind" => kind,
           "rule" => %{
             "id" => state.policy.id,
             "revision" => state.policy.revision,
             "identity" => state.policy.identity
           },
           "state_identity" => state.identity
         },
         details(kind, state)
       )}
    else
      _ -> {:error, :storage_unavailable}
    end
  end

  def project(_, _), do: {:error, :storage_unavailable}

  defp details("heartbeat", state),
    do: %{
      "status" => state.status,
      "heartbeat" => %{
        "observed_at" => Projection.scalar(state.observation.observed_at),
        "due_at" => Projection.scalar(state.due_at),
        "evaluated_at" => Projection.scalar(state.evaluated_at),
        "maximum_silence_ms" => Projection.scalar(state.policy.maximum_silence_ms)
      }
    }

  defp details("battery", state),
    do: %{
      "status" => state.status,
      "battery" => %{
        "measurement" => Projection.measurement(state.sample.measurement),
        "observed_at" => Projection.scalar(state.sample.observed_at),
        "evaluated_at" => Projection.scalar(state.evaluated_at),
        "low_threshold" => Projection.scalar(state.policy.low_threshold),
        "clear_threshold" => Projection.scalar(state.policy.clear_threshold),
        "maximum_age_ms" => Projection.scalar(state.policy.maximum_age_ms),
        "accept_suspect" => state.policy.accept_suspect
      }
    }

  defp details("transport_degradation", state),
    do: %{
      "status" => state.status,
      "transport_degradation" => %{
        "decision_status" => state.decision["status"],
        "decision_action" => state.decision["action"],
        "selected_candidate_id" => get_in(state.decision, ["selected", "candidate_id"]),
        "decided_at" => Projection.scalar(state.decision["evaluated_at"]),
        "evaluated_at" => Projection.scalar(state.evaluated_at),
        "healthy_candidate_ids" => state.policy.healthy_candidate_ids,
        "maximum_decision_age_ms" => Projection.scalar(state.policy.maximum_decision_age_ms)
      }
    }

  defp details("motion", state),
    do: %{
      "status" => state.motion_status,
      "motion" => %{
        "candidate_status" => state.candidate_status,
        "candidate_since" => optional_scalar(state.candidate_since),
        "last_received_outcome" => state.last_received_outcome,
        "active_trip" => trip(state.active_trip),
        "minimum_movement_ms" => Projection.scalar(state.policy.minimum_movement_ms),
        "minimum_stop_ms" => Projection.scalar(state.policy.minimum_stop_ms)
      }
    }

  defp details("geofence", state),
    do: %{
      "status" => membership(state.last_valid_membership, "status"),
      "geofence" => %{
        "fence" => %{
          "id" => state.fence.id,
          "revision" => state.fence.revision,
          "identity" => state.fence.identity
        },
        "membership_reason" => membership(state.last_valid_membership, "reason"),
        "membership_event_at" => optional_scalar(state.last_valid_event_at),
        "last_received_outcome" => state.last_received_outcome,
        "max_transition_gap_ms" => Projection.scalar(state.policy.max_transition_gap_ms)
      }
    }

  defp trip(nil), do: nil

  defp trip(trip),
    do: %{
      "id" => trip.id,
      "started_at" => Projection.scalar(trip.started_at),
      "confirmed_at" => Projection.scalar(trip.confirmed_at)
    }

  defp membership(nil, "status"), do: "unknown"
  defp membership(nil, _field), do: nil
  defp membership(value, field), do: value[field]

  defp optional_scalar(nil), do: nil
  defp optional_scalar(value), do: Projection.scalar(value)
end
