defmodule Wotex.Tracker.Service.RuleFixtures do
  @moduledoc false

  alias Wotex.Tracker.{
    BatteryTransition,
    Evidence,
    EvidenceBundle,
    Geofence,
    GeofenceTransition,
    HeartbeatTransition,
    Measurement,
    MeasurementSample,
    MotionTransition,
    PolicyFact,
    Position,
    PositionMovement,
    PositionOrder,
    PositionSample,
    TransportCandidate,
    TransportDegradation,
    TransportPolicy
  }

  alias Wotex.Tracker.Service.{Fixtures, RuleTransition, Store}

  @now 1_700_000_000_000

  @doc "Commits one changed rule result per supported kind and returns the final pure states."
  def commit_all(store, scope) do
    %{
      heartbeat: commit_heartbeat(store, scope),
      battery: commit_battery(store, scope),
      transport_degradation: commit_transport(store, scope),
      motion: commit_motion(store, scope),
      geofence: commit_geofence(store, scope)
    }
  end

  def commit_heartbeat(store, scope) do
    policy = heartbeat_policy()
    heartbeat = Fixtures.observation(%{id: "heartbeat-capture", observed_at: @now})
    {:ok, baseline} = HeartbeatTransition.evaluate(nil, heartbeat, policy, :live, @now)
    commit!(store, scope, nil, baseline)
    due_at = baseline["state"].due_at
    {:ok, overdue} = HeartbeatTransition.evaluate(baseline["state"], nil, policy, :live, due_at)
    commit!(store, scope, baseline["state"], overdue)
  end

  def commit_battery(store, scope) do
    policy = battery_policy()

    {:ok, normal} =
      BatteryTransition.evaluate(nil, battery("normal", 3.0, @now), policy, :live, @now)

    commit!(store, scope, nil, normal)

    {:ok, low} =
      BatteryTransition.evaluate(
        normal["state"],
        battery("low", 2.5, @now + 1),
        policy,
        :live,
        @now + 1
      )

    commit!(store, scope, normal["state"], low)
  end

  def commit_transport(store, scope) do
    transport_policy = transport_policy()
    policy = transport_degradation_policy(transport_policy)

    {:ok, healthy} =
      TransportPolicy.select([candidate()], request("healthy"), transport_policy, @now)

    {:ok, baseline} = TransportDegradation.evaluate(nil, healthy, policy, :live, @now)
    commit!(store, scope, nil, baseline)
    {:ok, unavailable} = TransportPolicy.select([], request("lost"), transport_policy, @now + 1)

    {:ok, degraded} =
      TransportDegradation.evaluate(baseline["state"], unavailable, policy, :live, @now + 1)

    commit!(store, scope, baseline["state"], degraded)
  end

  def commit_motion(store, scope) do
    policy = motion_policy()

    Enum.reduce(
      [{"first", 0, 0}, {"second", 0.0001, 1_000}, {"third", 0.0002, 2_000}],
      nil,
      fn {id, longitude, offset}, previous ->
        {:ok, result} =
          MotionTransition.evaluate(
            previous,
            position(id, longitude, @now + offset),
            policy,
            :live,
            @now + offset
          )

        commit!(store, scope, previous, result)
      end
    )
  end

  def commit_geofence(store, scope) do
    fence = fence()
    policy = geofence_policy()
    outside = position("outside", 0.002, @now)
    {:ok, baseline} = GeofenceTransition.evaluate(nil, fence, outside, policy, :live, @now)
    commit!(store, scope, nil, baseline)
    inside = position("inside", 0, @now + 1_000)

    {:ok, entered} =
      GeofenceTransition.evaluate(baseline["state"], fence, inside, policy, :live, @now + 1_000)

    commit!(store, scope, baseline["state"], entered)
  end

  def heartbeat_policy do
    {:ok, value} =
      HeartbeatTransition.new(%{
        id: "silence",
        revision: "silence-v1",
        maximum_silence_ms: 10,
        future_skew_ms: 0
      })

    value
  end

  def battery_policy do
    {:ok, value} =
      BatteryTransition.new(%{
        id: "low-battery",
        revision: "low-battery-v1",
        measurement_kind: "batteryVoltage",
        unit: "V",
        low_threshold: 2.5,
        clear_threshold: 2.8,
        maximum_age_ms: 86_400_000,
        future_skew_ms: 0,
        accept_suspect: false
      })

    value
  end

  def fence do
    {:ok, fence} =
      Geofence.new(%{
        id: "yard",
        revision: "yard-v1",
        shape: %{kind: :circle, latitude: 0, longitude: 0, radius_m: 100},
        boundary: :inside,
        uncertainty: :coordinate_only
      })

    fence
  end

  def now, do: @now

  defp commit!(store, scope, previous, result) do
    {:ok, transition} = RuleTransition.new(scope, previous, result)
    {:ok, _receipt} = Store.commit_rule(store, transition)
    result["state"]
  end

  defp battery(id, value, observed_at) do
    capture = Fixtures.observation(%{id: "battery-capture-#{id}", observed_at: observed_at})

    {:ok, measurement} =
      Measurement.new(%{
        kind: "batteryVoltage",
        value: value,
        unit: "V",
        availability: :available,
        quality: :valid,
        raw: value,
        reason: "fixture"
      })

    {:ok, claim} = Measurement.to_map(measurement)

    {:ok, evidence} =
      Evidence.new(%{
        id: "battery-#{id}",
        kind: :measurement,
        claim: claim,
        source_observation_ids: [capture.id],
        evidence_ids: [],
        profile: {"battery", "1"},
        decoder: {"battery", "1"},
        confidence: :exact,
        reasons: ["fixture"],
        association_id: nil
      })

    {:ok, bundle} = EvidenceBundle.new([capture], [evidence])
    {:ok, sample} = MeasurementSample.new(evidence.id, bundle)
    sample
  end

  defp order_policy(revision) do
    {:ok, value} =
      PositionOrder.new(%{
        revision: revision,
        event_time: :trusted_fix,
        future_skew_ms: 0,
        late_window_ms: 10_000,
        sequence: :none
      })

    value
  end

  def motion_policy do
    {:ok, movement_policy} =
      PositionMovement.new(%{
        id: "movement",
        revision: "movement-v1",
        order_policy: order_policy("motion-order-v1"),
        moving_speed_m_s: 1.0,
        stationary_speed_m_s: 0.1,
        moving_distance_m: 1.0,
        stationary_distance_m: 0.5,
        max_plausible_speed_m_s: 10_000.0,
        max_gap_ms: 10_000,
        uncertainty: :coordinate_only
      })

    {:ok, policy} =
      MotionTransition.new(%{
        id: "trips",
        revision: "trips-v1",
        movement_policy: movement_policy,
        minimum_movement_ms: 1_000,
        minimum_stop_ms: 1_000
      })

    policy
  end

  def geofence_policy do
    {:ok, policy} =
      GeofenceTransition.new(%{
        id: "yard-membership",
        revision: "yard-membership-v1",
        order_policy: order_policy("geofence-order-v1"),
        max_transition_gap_ms: 10_000
      })

    policy
  end

  def position(id, longitude, event_at) do
    capture = Fixtures.observation(%{id: "position-capture-#{id}", observed_at: event_at})

    {:ok, evidence} =
      Evidence.new(%{
        id: "position-#{id}",
        kind: :position,
        claim: %{
          "schema" => "wtr.position.v1",
          "latitude" => 0,
          "longitude" => longitude,
          "altitude_m" => nil,
          "speed_m_s" => nil,
          "horizontal_accuracy_m" => nil,
          "accuracy_kind" => "unknown",
          "source" => "gnss",
          "fix_at" => event_at,
          "device_at" => nil,
          "received_at" => event_at,
          "fix_clock" => "trusted",
          "device_clock" => "unknown",
          "availability" => "available",
          "quality" => "valid",
          "source_units" => %{
            "latitude" => "degree",
            "longitude" => "degree",
            "altitude" => nil,
            "speed" => nil,
            "accuracy" => nil,
            "fix_time" => "unix-ms",
            "device_time" => nil,
            "receiver_time" => "unix-ms"
          },
          "conversion_revision" => "fixture-v1",
          "receiver_observation_id" => capture.id,
          "raw" => %{}
        },
        source_observation_ids: [capture.id],
        evidence_ids: [],
        profile: {"position", "1"},
        decoder: {"position", "1"},
        confidence: :exact,
        reasons: ["fixture"],
        association_id: nil
      })

    {:ok, bundle} = EvidenceBundle.new([capture], [evidence])
    {:ok, position} = Position.new(evidence.id, bundle)
    {:ok, sample} = PositionSample.new(position, bundle)
    sample
  end

  defp transport_policy do
    {:ok, value} =
      TransportPolicy.new(%{
        id: "transport",
        revision: "transport-v1",
        fact_policy_revision: "facts-v1",
        ordinary_order: ["lorawan"],
        critical_order: ["lorawan"],
        maximum_fact_age_ms: 1_000,
        future_skew_ms: 0,
        ordinary_max_cost_class: 100,
        critical_max_cost_class: 100,
        ordinary_max_power_class: 100,
        critical_max_power_class: 100,
        ordinary_acknowledgement: :none,
        critical_acknowledgement: :none,
        ordinary_no_route: :store_and_retry,
        critical_no_route: :unavailable
      })

    value
  end

  defp transport_degradation_policy(transport_policy) do
    {:ok, value} =
      TransportDegradation.new(%{
        id: "uplink",
        revision: "uplink-v1",
        transport_policy: transport_policy,
        healthy_candidate_ids: ["lorawan"],
        maximum_decision_age_ms: 86_400_000,
        future_skew_ms: 0
      })

    value
  end

  defp candidate do
    {:ok, value} =
      TransportCandidate.new(%{
        id: "lorawan",
        bearer: "lorawan-eu868",
        application_protocol: "fixture-protocol",
        capability:
          fact("capability", TransportCandidate.capability_predicate("lorawan"), :capability),
        connectivity:
          fact("connectivity", TransportCandidate.connectivity_predicate("lorawan"), :transport),
        cost_class: 10,
        power_class: 10,
        acknowledgement_layers: []
      })

    value
  end

  defp fact(id, predicate, kind) do
    observation = Fixtures.observation(%{id: "transport-capture-#{id}", observed_at: @now})

    {:ok, evidence} =
      Evidence.new(%{
        id: id,
        kind: kind,
        claim: %{
          "schema" => "wtr.policy-fact.v1",
          "predicate" => predicate,
          "status" => "true",
          "policy_revision" => "facts-v1",
          "reason" => "fixture"
        },
        source_observation_ids: [observation.id],
        evidence_ids: [],
        profile: {"transport", "1"},
        decoder: {"transport", "1"},
        confidence: :exact,
        reasons: ["fixture"],
        association_id: nil
      })

    {:ok, bundle} = EvidenceBundle.new([observation], [evidence])
    {:ok, value} = PolicyFact.new(id, bundle)
    value
  end

  defp request(id),
    do: %{
      id: id,
      severity: :critical,
      purpose: :event,
      maximum_cost_class: 100,
      maximum_power_class: 100,
      acknowledgement: nil
    }
end
