# Production archive consumer: no repository source imports and no host packages.
alias Wotex.Tracker.Service

alias Wotex.Tracker.{
  BatteryTransition,
  Evidence,
  EvidenceBundle,
  Geofence,
  GeofenceCrossing,
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
  QuerySpec,
  SuspiciousMovement,
  TransportCandidate,
  TransportDegradation,
  TransportPolicy
}

alias Wotex.Tracker.Service.{
  Codec,
  Credentials,
  Cursor,
  ForwardItem,
  Identifier,
  OperationalTelemetry,
  Projection,
  RuleEvent,
  RuleTransition,
  Store,
  Update
}

alias Wotex.Binding.HTTP
alias Wotex.Runtime.{ConsumedThing, Context, Result, Subscription}
alias Wotex.Tracker.Service.HTTP.{LoopbackClient, Server}

defmodule ArchivePeerCredentials do
  @moduledoc false
  use GenServer
  @behaviour Wotex.Runtime.Credentials
  def start_link(token), do: GenServer.start_link(__MODULE__, token)
  @impl true
  def init(token), do: {:ok, token}
  @impl true
  def handle_call(:resolve, _, token), do: {:reply, {:ok, token}, token}
  @impl true
  def format_status(status), do: Map.put(status, :state, :redacted)
  @impl Wotex.Runtime.Credentials
  def resolve(%{names: ["bearer"]}, _, _, vault), do: GenServer.call(vault, :resolve)
end

[] = Application.spec(:wotex_tracker_service, :mod)

for module <- [Phoenix, Nerves, Nx, Wotex.Directory] do
  false = Code.ensure_loaded?(module)
end

[
  "request.stop",
  "query.stop",
  "ingest.stop",
  "store.stop",
  "queue.stop",
  "publication.stop",
  "resource.stop"
] =
  Enum.map(OperationalTelemetry.contracts(), & &1.name)

directory = Path.expand("store")
File.mkdir!(directory)
File.chmod!(directory, 0o700)

token = Credentials.generate_token()
{:ok, digest} = Credentials.token_digest(token)

{:ok, credentials} =
  Credentials.new(%{
    instance_id: "archive-instance",
    secret_key: :crypto.strong_rand_bytes(32),
    entries: [
      %{
        id: "archive-credential",
        principal: "consumer",
        token_sha256: digest,
        grants: %{"archive" => ~w(read raw ingest enroll admin)},
        expires_at: 1_700_000_001_000
      }
    ]
  })

{:ok, access} =
  Credentials.authenticate(credentials, token, "archive", "ingest", 1_700_000_000_000)

binding = %{
  instance: Credentials.instance_id(credentials),
  principal: "consumer",
  scope: "archive",
  purpose: "page"
}

cursor_data = %{
  "kind" => "observations",
  "generation" => "1",
  "after" => "private-id",
  "limit" => 10
}

key = Credentials.derive_key(credentials, :cursor)
{:ok, cursor} = Cursor.issue(key, binding, cursor_data, 1_700_000_000_000)
{:ok, ^cursor_data} = Cursor.open(key, binding, cursor, 1_700_000_000_000)

{:error, :invalid_cursor} =
  Cursor.open(key, %{binding | scope: "other"}, cursor, 1_700_000_000_000)

%{"type" => "wide_integer", "value" => "9007199254740993"} =
  Projection.scalar(9_007_199_254_740_993)

{:ok, observation} =
  Wotex.Tracker.observation(%{
    id: "archive-observation",
    observed_at: 1_700_000_000_000,
    ingress: "imported",
    source: %{"number" => 1, "float" => 1.0, "wide" => 9_007_199_254_740_993},
    addressing: %{},
    radio: %{},
    transport: %{},
    provenance: %{},
    payload: {:bytes, <<0, 255>>}
  })

{:ok, update} =
  Update.new(%{
    principal: "consumer",
    authority: access,
    scope: "archive",
    operation_id: "import-1",
    expected_generation: "0",
    request: %{"operation" => "import"},
    now: 1_700_000_000_000,
    observation: observation,
    records: [
      %{kind: "state", id: "sample", value: %{"zero" => 0, "missing" => nil, "false" => false}}
    ],
    events: [%{"type" => "observation.admitted", "data" => %{"id" => "archive-observation"}}],
    publication: nil
  })

before_processes = MapSet.new(Process.list())
{:ok, pid} = Store.start_link(directory: directory, credentials: credentials)
store = Store.handle(pid)
{:ok, result} = Store.mutate(store, update)
"committed" = result["outcome"]
{:ok, ^result} = Store.mutate(store, update)
{:ok, %{"schema" => "3", "sqlite" => "3.53.4"}} = Store.readiness(store)

transport_fact = fn id, predicate, kind ->
  {:ok, evidence} =
    Evidence.new(%{
      id: id,
      kind: kind,
      claim: %{
        "schema" => "wtr.policy-fact.v1",
        "predicate" => predicate,
        "status" => "true",
        "policy_revision" => "archive-facts-v1",
        "reason" => "archive_fixture"
      },
      source_observation_ids: [observation.id],
      evidence_ids: [],
      profile: {"archive-transport", "1"},
      decoder: {"archive-transport", "1"},
      confidence: :exact,
      reasons: ["archive_fixture"],
      association_id: nil
    })

  {:ok, bundle} = EvidenceBundle.new([observation], [evidence])
  {:ok, fact} = PolicyFact.new(evidence.id, bundle)
  fact
end

{:ok, route} =
  TransportCandidate.new(%{
    id: "lorawan",
    bearer: "lorawan-eu868",
    application_protocol: "fixture-protocol",
    capability:
      transport_fact.(
        "archive-route-capability",
        TransportCandidate.capability_predicate("lorawan"),
        :capability
      ),
    connectivity:
      transport_fact.(
        "archive-route-connectivity",
        TransportCandidate.connectivity_predicate("lorawan"),
        :transport
      ),
    cost_class: 10,
    power_class: 10,
    acknowledgement_layers: []
  })

{:ok, transport_policy} =
  TransportPolicy.new(%{
    id: "archive-transport",
    revision: "archive-transport-v1",
    fact_policy_revision: "archive-facts-v1",
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

transport_request = %{
  id: "archive-route-request",
  severity: :critical,
  purpose: :event,
  maximum_cost_class: 100,
  maximum_power_class: 100,
  acknowledgement: nil
}

{:ok, transport_health_policy} =
  TransportDegradation.new(%{
    id: "archive-transport-health",
    revision: "archive-health-v1",
    transport_policy: transport_policy,
    healthy_candidate_ids: ["lorawan"],
    maximum_decision_age_ms: 1_000,
    future_skew_ms: 0
  })

{:ok, healthy_decision} =
  TransportPolicy.select([route], transport_request, transport_policy, update.now)

{:ok, healthy_result} =
  TransportDegradation.evaluate(
    nil,
    healthy_decision,
    transport_health_policy,
    :live,
    update.now
  )

{:ok, healthy_transition} = RuleTransition.new("archive-rules", nil, healthy_result)

{:ok, %{"generation" => "1", "event_disposition" => "none"}} =
  Store.commit_rule(store, healthy_transition)

{:ok, heartbeat_policy} =
  HeartbeatTransition.new(%{
    id: "archive-heartbeat",
    revision: "archive-heartbeat-v1",
    maximum_silence_ms: 10,
    future_skew_ms: 0
  })

{:ok, heartbeat_result} =
  HeartbeatTransition.evaluate(nil, observation, heartbeat_policy, :live, update.now)

{:ok, heartbeat_transition} =
  RuleTransition.new("archive-heartbeat", nil, heartbeat_result)

{:ok, %{"generation" => "1", "event_disposition" => "none"}} =
  Store.commit_rule(store, heartbeat_transition)

battery_sample = fn id, value, observed_at ->
  capture = %{observation | id: "archive-battery-capture-#{id}", observed_at: observed_at}

  {:ok, measurement} =
    Measurement.new(%{
      kind: "batteryVoltage",
      value: value,
      unit: "V",
      availability: :available,
      quality: :valid,
      raw: value,
      reason: "archive_fixture"
    })

  {:ok, claim} = Measurement.to_map(measurement)

  {:ok, evidence} =
    Evidence.new(%{
      id: "archive-battery-#{id}",
      kind: :measurement,
      claim: claim,
      source_observation_ids: [capture.id],
      evidence_ids: [],
      profile: {"archive-battery", "1"},
      decoder: {"archive-battery", "1"},
      confidence: :exact,
      reasons: ["archive_fixture"],
      association_id: nil
    })

  {:ok, bundle} = EvidenceBundle.new([capture], [evidence])
  {:ok, sample} = MeasurementSample.new(evidence.id, bundle)
  sample
end

{:ok, battery_policy} =
  BatteryTransition.new(%{
    id: "archive-battery",
    revision: "archive-battery-v1",
    measurement_kind: "batteryVoltage",
    unit: "V",
    low_threshold: 2.5,
    clear_threshold: 2.8,
    maximum_age_ms: 1_000,
    future_skew_ms: 0,
    accept_suspect: false
  })

{:ok, battery_result} =
  BatteryTransition.evaluate(
    nil,
    battery_sample.("normal", 3.0, update.now),
    battery_policy,
    :live,
    update.now
  )

{:ok, battery_transition} = RuleTransition.new("archive-battery", nil, battery_result)

{:ok, %{"generation" => "1", "event_disposition" => "none"}} =
  Store.commit_rule(store, battery_transition)

motion_sample = fn id, longitude, event_at ->
  capture = %{observation | id: "archive-motion-capture-#{id}", observed_at: event_at}

  {:ok, evidence} =
    Evidence.new(%{
      id: "archive-position-#{id}",
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
        "conversion_revision" => "archive-v1",
        "receiver_observation_id" => capture.id,
        "raw" => %{}
      },
      source_observation_ids: [capture.id],
      evidence_ids: [],
      profile: {"archive-position", "1"},
      decoder: {"archive-position", "1"},
      confidence: :exact,
      reasons: ["archive_fixture"],
      association_id: nil
    })

  {:ok, bundle} = EvidenceBundle.new([capture], [evidence])
  {:ok, position} = Position.new(evidence.id, bundle)
  {:ok, sample} = PositionSample.new(position, bundle)
  sample
end

{:ok, motion_order_policy} =
  PositionOrder.new(%{
    revision: "archive-motion-order-v1",
    event_time: :trusted_fix,
    future_skew_ms: 0,
    late_window_ms: 10_000,
    sequence: :none
  })

{:ok, motion_movement_policy} =
  PositionMovement.new(%{
    id: "archive-movement",
    revision: "archive-movement-v1",
    order_policy: motion_order_policy,
    moving_speed_m_s: 1.0,
    stationary_speed_m_s: 0.1,
    moving_distance_m: 1.0,
    stationary_distance_m: 0.5,
    max_plausible_speed_m_s: 10_000.0,
    max_gap_ms: 10_000,
    uncertainty: :coordinate_only
  })

{:ok, motion_policy} =
  MotionTransition.new(%{
    id: "archive-motion",
    revision: "archive-motion-v1",
    movement_policy: motion_movement_policy,
    minimum_movement_ms: 1_000,
    minimum_stop_ms: 1_000
  })

{:ok, motion_baseline_result} =
  MotionTransition.evaluate(
    nil,
    motion_sample.("first", 0, update.now),
    motion_policy,
    :live,
    update.now
  )

{:ok, motion_baseline_transition} =
  RuleTransition.new("archive-motion", nil, motion_baseline_result)

{:ok, %{"generation" => "1", "event_disposition" => "none"}} =
  Store.commit_rule(store, motion_baseline_transition)

{:ok, motion_candidate_result} =
  MotionTransition.evaluate(
    motion_baseline_result["state"],
    motion_sample.("second", 0.0001, update.now + 1_000),
    motion_policy,
    :live,
    update.now + 1_000
  )

{:ok, motion_candidate_transition} =
  RuleTransition.new("archive-motion", motion_baseline_result["state"], motion_candidate_result)

{:ok, %{"generation" => "2", "event_disposition" => "none"}} =
  Store.commit_rule(store, motion_candidate_transition)

{:ok, geofence} =
  Geofence.new(%{
    id: "archive-yard",
    revision: "archive-yard-v1",
    shape: %{kind: :circle, latitude: 0, longitude: 0, radius_m: 100},
    boundary: :inside,
    uncertainty: :coordinate_only
  })

{:ok, geofence_order_policy} =
  PositionOrder.new(%{
    revision: "archive-geofence-order-v1",
    event_time: :trusted_fix,
    future_skew_ms: 0,
    late_window_ms: 10_000,
    sequence: :none
  })

{:ok, geofence_policy} =
  GeofenceTransition.new(%{
    id: "archive-yard-membership",
    revision: "archive-yard-membership-v1",
    order_policy: geofence_order_policy,
    max_transition_gap_ms: 10_000
  })

{:ok, geofence_baseline_result} =
  GeofenceTransition.evaluate(
    nil,
    geofence,
    motion_sample.("geofence-outside", 0.002, update.now),
    geofence_policy,
    :live,
    update.now
  )

{:ok, geofence_baseline_transition} =
  RuleTransition.new("archive-geofence", nil, geofence_baseline_result)

{:ok, %{"generation" => "1", "event_disposition" => "none"}} =
  Store.commit_rule(store, geofence_baseline_transition)

{:ok, crossing_policy} =
  GeofenceCrossing.new(%{
    id: "archive-crossing",
    revision: "archive-crossing-v1",
    order_policy: geofence_order_policy,
    max_gap_ms: 10_000,
    max_distance_m: 500
  })

crossing_from = motion_sample.("crossing-from", -0.002, update.now)
crossing_to = motion_sample.("crossing-to", 0.002, update.now + 1)

{:ok, crossing_result} =
  GeofenceCrossing.evaluate(
    geofence,
    crossing_from,
    crossing_to,
    crossing_policy,
    :replay,
    update.now + 1
  )

{:ok, crossing_intent} =
  RuleEvent.geofence_crossing(
    "archive-crossing",
    geofence,
    crossing_from,
    crossing_to,
    crossing_policy,
    crossing_result
  )

{:ok, %{"generation" => "1", "event_disposition" => "recorded"} = crossing_receipt} =
  Store.commit_rule_event(store, crossing_intent)

third_motion_sample = motion_sample.("third", 0.0002, update.now + 2_000)

{:ok, suspicious_motion_result} =
  MotionTransition.evaluate(
    motion_candidate_result["state"],
    third_motion_sample,
    motion_policy,
    :replay,
    update.now + 2_000
  )

suspicious_fact = fn id, predicate, status, kind ->
  capture = %{
    observation
    | id: "archive-suspicious-capture-#{id}",
      observed_at: update.now + 2_000
  }

  {:ok, evidence} =
    Evidence.new(%{
      id: id,
      kind: kind,
      claim: %{
        "schema" => "wtr.policy-fact.v1",
        "predicate" => predicate,
        "status" => status,
        "policy_revision" => "archive-suspicious-facts-v1",
        "reason" => "archive_fixture"
      },
      source_observation_ids: [capture.id],
      evidence_ids: [],
      profile: {"archive-suspicious", "1"},
      decoder: {"archive-suspicious", "1"},
      confidence: :exact,
      reasons: ["archive_fixture"],
      association_id: nil
    })

  {:ok, bundle} = EvidenceBundle.new([capture], [evidence])
  {:ok, fact} = PolicyFact.new(evidence.id, bundle)
  fact
end

armed_fact = suspicious_fact.("archive-armed", "asset.armed", "true", :identity)
owner_fact = suspicious_fact.("archive-owner", "owner.present", "false", :transport)

{:ok, suspicious_policy} =
  SuspiciousMovement.new(%{
    id: "archive-suspicious",
    revision: "archive-suspicious-v1",
    motion_policy: motion_policy,
    armed_predicate: "asset.armed",
    owner_presence_predicate: "owner.present",
    maximum_fact_age_ms: 1_000,
    future_skew_ms: 0,
    owner_unknown_as_absent: false
  })

{:ok, suspicious_result} =
  SuspiciousMovement.evaluate(
    suspicious_motion_result["state"],
    armed_fact,
    owner_fact,
    suspicious_policy,
    :replay,
    update.now + 2_000
  )

{:ok, suspicious_intent} =
  RuleEvent.suspicious_movement(
    "archive-suspicious",
    suspicious_motion_result["state"],
    armed_fact,
    owner_fact,
    suspicious_policy,
    suspicious_result
  )

{:ok, %{"generation" => "1", "event_disposition" => "recorded"} = suspicious_receipt} =
  Store.commit_rule_event(store, suspicious_intent)

{:ok, forward_item} =
  ForwardItem.new(%{
    scope: "archive",
    id: "archive-forward",
    candidate_id: "cellular",
    bearer: "lte-m",
    application_protocol: "fixture-protocol",
    payload: %{"event" => "alarm"},
    source: :reliable,
    admitted_at: update.now,
    required_acknowledgement: :durable_admission
  })

{:ok, %{"status" => "pending"}} = Store.enqueue_forward(store, forward_item)
GenServer.stop(pid)
{:ok, pid} = Store.start_link(directory: directory, credentials: credentials)
store = Store.handle(pid)
{:ok, ^result} = Store.operation(store, "archive", "consumer", "import-1", update.now)

{:ok, durable_health} =
  Store.rule_state(
    store,
    "archive-rules",
    "transport_degradation",
    transport_health_policy.id
  )

{:ok, restored_health} = TransportDegradation.state_from_map(durable_health["state"])
true = restored_health === healthy_result["state"]

{:ok, unavailable_decision} =
  TransportPolicy.select(
    [],
    %{transport_request | id: "archive-route-unavailable"},
    transport_policy,
    update.now + 1
  )

{:ok, degraded_result} =
  TransportDegradation.evaluate(
    restored_health,
    unavailable_decision,
    transport_health_policy,
    :replay,
    update.now + 1
  )

{:ok, degraded_transition} =
  RuleTransition.new("archive-rules", restored_health, degraded_result)

{:ok, %{"generation" => "2", "event_disposition" => "recorded"} = degraded_receipt} =
  Store.commit_rule(store, degraded_transition)

{:ok, %{"disposition" => "duplicate", "generation" => "2"}} =
  Store.commit_rule(store, degraded_transition)

{:ok,
 %{
   "event" => %{"kind" => "transport.degraded"},
   "mode" => "replay",
   "physical_action_dispatch" => "prohibited"
 }} = Store.rule_event(store, "archive-rules", degraded_receipt["event_id"])

{:ok, durable_heartbeat} =
  Store.rule_state(store, "archive-heartbeat", "heartbeat", heartbeat_policy.id)

{:ok, restored_heartbeat} =
  HeartbeatTransition.state_from_map(durable_heartbeat["state"])

true = restored_heartbeat === heartbeat_result["state"]

{:ok, overdue_result} =
  HeartbeatTransition.evaluate(
    restored_heartbeat,
    nil,
    heartbeat_policy,
    :replay,
    restored_heartbeat.due_at
  )

{:ok, overdue_transition} =
  RuleTransition.new("archive-heartbeat", restored_heartbeat, overdue_result)

{:ok, %{"generation" => "2", "event_disposition" => "recorded"} = overdue_receipt} =
  Store.commit_rule(store, overdue_transition)

{:ok, %{"disposition" => "duplicate", "generation" => "2"}} =
  Store.commit_rule(store, overdue_transition)

{:ok,
 %{
   "event" => %{"kind" => "heartbeat.overdue"},
   "mode" => "replay",
   "physical_action_dispatch" => "prohibited"
 }} = Store.rule_event(store, "archive-heartbeat", overdue_receipt["event_id"])

{:ok, durable_battery} =
  Store.rule_state(store, "archive-battery", "battery", battery_policy.id)

{:ok, restored_battery} = BatteryTransition.state_from_map(durable_battery["state"])
true = restored_battery === battery_result["state"]

{:ok, low_battery_result} =
  BatteryTransition.evaluate(
    restored_battery,
    battery_sample.("low", 2.5, update.now + 1),
    battery_policy,
    :replay,
    update.now + 1
  )

{:ok, low_battery_transition} =
  RuleTransition.new("archive-battery", restored_battery, low_battery_result)

{:ok, %{"generation" => "2", "event_disposition" => "recorded"} = battery_receipt} =
  Store.commit_rule(store, low_battery_transition)

{:ok, %{"disposition" => "duplicate", "generation" => "2"}} =
  Store.commit_rule(store, low_battery_transition)

{:ok,
 %{
   "event" => %{"kind" => "battery.low"},
   "mode" => "replay",
   "physical_action_dispatch" => "prohibited"
 }} = Store.rule_event(store, "archive-battery", battery_receipt["event_id"])

{:ok, durable_motion} =
  Store.rule_state(store, "archive-motion", "motion", motion_policy.id)

{:ok, restored_motion} = MotionTransition.state_from_map(durable_motion["state"])
true = restored_motion === motion_candidate_result["state"]

{:ok, started_motion_result} =
  MotionTransition.evaluate(
    restored_motion,
    third_motion_sample,
    motion_policy,
    :replay,
    update.now + 2_000
  )

{:ok, started_motion_transition} =
  RuleTransition.new("archive-motion", restored_motion, started_motion_result)

{:ok, %{"generation" => "3", "event_disposition" => "recorded"} = motion_receipt} =
  Store.commit_rule(store, started_motion_transition)

{:ok, %{"disposition" => "duplicate", "generation" => "3"}} =
  Store.commit_rule(store, started_motion_transition)

{:ok,
 %{
   "event" => %{"kind" => "trip.started"},
   "mode" => "replay",
   "physical_action_dispatch" => "prohibited"
 }} = Store.rule_event(store, "archive-motion", motion_receipt["event_id"])

{:ok, durable_geofence} =
  Store.rule_state(store, "archive-geofence", "geofence", geofence_policy.id)

{:ok, restored_geofence} = GeofenceTransition.state_from_map(durable_geofence["state"])
true = restored_geofence === geofence_baseline_result["state"]

{:ok, entered_geofence_result} =
  GeofenceTransition.evaluate(
    restored_geofence,
    geofence,
    motion_sample.("geofence-inside", 0, update.now + 1_000),
    geofence_policy,
    :replay,
    update.now + 1_000
  )

{:ok, entered_geofence_transition} =
  RuleTransition.new("archive-geofence", restored_geofence, entered_geofence_result)

{:ok, %{"generation" => "2", "event_disposition" => "recorded"} = geofence_receipt} =
  Store.commit_rule(store, entered_geofence_transition)

{:ok, %{"disposition" => "duplicate", "generation" => "2"}} =
  Store.commit_rule(store, entered_geofence_transition)

{:ok,
 %{
   "event" => %{"kind" => "geofence.entered"},
   "mode" => "replay",
   "physical_action_dispatch" => "prohibited"
 }} = Store.rule_event(store, "archive-geofence", geofence_receipt["event_id"])

{:ok,
 %{
   "event" => %{"kind" => "geofence.crossing_inferred"},
   "mode" => "replay",
   "physical_action_dispatch" => "prohibited"
 }} = Store.rule_event(store, "archive-crossing", crossing_receipt["event_id"])

{:ok, %{"generation" => "1", "disposition" => "duplicate"}} =
  Store.commit_rule_event(store, crossing_intent)

{:ok,
 %{
   "event" => %{"kind" => "suspicious_movement"},
   "mode" => "replay",
   "physical_action_dispatch" => "prohibited"
 }} = Store.rule_event(store, "archive-suspicious", suspicious_receipt["event_id"])

{:ok, %{"generation" => "1", "disposition" => "duplicate"}} =
  Store.commit_rule_event(store, suspicious_intent)

{:ok, %{"status" => "pending"}} =
  Store.forward_status(store, "archive", forward_item.id)

{:ok, %{"items" => [%{"id" => "archive-forward", "attempt" => 1}]}} =
  Store.claim_forward(store, "archive", update.now, 1, 1_000)

{:ok, %{"status" => "delivered", "completion" => %{"layer" => "durable_admission"}}} =
  Store.complete_forward(
    store,
    "archive",
    forward_item.id,
    forward_item.identity,
    %{
      status: :acknowledged,
      layer: :durable_admission,
      at: update.now + 1,
      reference: "archive-server-admission"
    }
  )

{:ok, %{"items" => [%{"value" => document}]}} =
  Store.authorized_snapshot(
    store,
    access,
    "raw",
    %{
      scope: "archive",
      kind: "observations",
      generation: "1",
      after: "",
      limit: 10
    },
    update.now
  )

{:ok, restored} = Wotex.Tracker.Observation.from_map(document)
true = restored === observation

{:ok, %{"items" => [_]}} =
  Store.authorized_events(store, access, %{
    scope: "archive",
    after: "0",
    limit: 10,
    now: update.now
  })

{:ok, service} =
  Service.new(%{store: store, credentials: credentials, base_url: "http://127.0.0.1:43210"})

{:ok, document} =
  Wotex.Tracker.Observation.to_map(%{
    observation
    | id: "ruuvi-fixture",
      ingress: "ble",
      transport: %{"manufacturer_id" => 1177},
      payload: {:bytes, Base.decode16!("0512FC5394C37C0004FFFC040CAC364200CDCBB8334C884F")}
  })

{:ok, imported} =
  Service.submit(
    service,
    token,
    "archive",
    Identifier.uuid(),
    %{
      "observation" => document,
      "expected_generation" => "1"
    },
    update.now
  )

{:ok, enrolled} =
  Service.enroll(
    service,
    token,
    "archive",
    Identifier.uuid(),
    %{
      "observation_id" => imported["data"]["observation_id"],
      "title" => "Archive sensor",
      "owner_confirmed" => true,
      "expected_generation" => "2"
    },
    update.now
  )

thing = enrolled["data"]["thing_id"]
operation = Identifier.uuid()
request = %{"thing_id" => thing, "expected_generation" => "3"}
{:ok, receipt} = Service.materialize(service, token, "archive", operation, request, update.now)
{:ok, %{"value" => td}} = Service.get(service, token, "archive", "things", thing, update.now)
{:ok, _} = Wotex.ThingDescription.from_map(td)
^thing = td["id"]
GenServer.stop(pid)
{:ok, pid} = Store.start_link(directory: directory, credentials: credentials)
store = Store.handle(pid)
service = %{service | store: store}
{:ok, ^receipt} = Service.materialize(service, token, "archive", operation, request, update.now)
{:ok, %{"value" => ^td}} = Service.get(service, token, "archive", "things", thing, update.now)

later_document = %{document | "id" => "later-ruuvi-fixture"}

{:ok, later} =
  Service.submit(
    service,
    token,
    "archive",
    Identifier.uuid(),
    %{"observation" => later_document, "expected_generation" => "4"},
    update.now
  )

association_operation = Identifier.uuid()

association_request = %{
  "thing_id" => thing,
  "observation_id" => later["data"]["observation_id"],
  "owner_confirmed" => true,
  "expected_generation" => "5"
}

{:ok, associated} =
  Service.associate(
    service,
    token,
    "archive",
    association_operation,
    association_request,
    update.now
  )

{:ok, ^associated} =
  Service.associate(
    service,
    token,
    "archive",
    association_operation,
    association_request,
    update.now
  )

{:ok, %{"generation" => "7"}} =
  Service.materialize(
    service,
    token,
    "archive",
    Identifier.uuid(),
    %{"thing_id" => thing, "expected_generation" => "6"},
    update.now
  )

{:ok, query_spec} =
  QuerySpec.new(%{
    id: "archive-temperature-history",
    revision: "archive-query-v1",
    dataset: :measurements,
    measurement: "temperature",
    unit: "Cel",
    series: [thing],
    qualities: [:valid],
    from_at: update.now,
    to_at: update.now + 1,
    timezone: "Etc/UTC",
    bucket_ms: 1,
    aggregation: :last,
    order: :ascending,
    max_points: 1
  })

{:ok, query_document} = QuerySpec.to_map(query_spec)

{:ok,
 %{
   "schema" => "wtr.query-result.v1",
   "scanned_rows" => 2,
   "qualified_rows" => 2,
   "series" => [%{"points" => [%{"value" => 24.3}]}]
 }} = Service.analytics(service, token, "archive", query_document, update.now)

{:ok, paged_query_spec} =
  query_spec
  |> Map.from_struct()
  |> Map.drop([:identity])
  |> Map.merge(%{to_at: update.now + 2, max_points: 2})
  |> QuerySpec.new()

{:ok, paged_query_document} = QuerySpec.to_map(paged_query_spec)

page_request = %{
  "schema" => "wtr.query-page-request.v1",
  "query" => paged_query_document,
  "page_size" => 1,
  "cursor" => nil
}

{:ok,
 %{
   "generation" => "7",
   "result" => %{
     "snapshot" => paged_snapshot,
     "series" => [%{"points" => [%{"value" => 24.3}]}]
   },
   "cursor" => page_cursor
 }} = Service.analytics_page(service, token, "archive", page_request, update.now)

{:ok,
 %{
   "generation" => "7",
   "result" => %{"snapshot" => ^paged_snapshot, "series" => [%{"points" => []}]},
   "cursor" => nil
 }} =
  Service.analytics_page(
    service,
    token,
    "archive",
    %{page_request | "cursor" => page_cursor},
    update.now
  )

save_operation = Identifier.uuid()

save_request = %{
  "id" => "archive-temperature",
  "title" => "Archive temperature",
  "query" => query_document,
  "visualization" => %{
    "type" => "line",
    "show_legend" => true,
    "show_points" => false
  },
  "expected_generation" => "7"
}

{:ok, %{"generation" => "8", "data" => %{"query_id" => "archive-temperature"}} = saved} =
  Service.save_query(service, token, "archive", save_operation, save_request, update.now)

{:ok, ^saved} =
  Service.save_query(service, token, "archive", save_operation, save_request, update.now)

{:ok, %{"value" => %{"query" => ^query_document, "owner" => "wtr1_" <> _}}} =
  Service.get(service, token, "archive", "saved_queries", "archive-temperature", update.now)

{:ok, %{"spec" => ^query_document, "series" => [%{"points" => [%{"value" => 24.3}]}]}} =
  Service.execute_saved_query(service, token, "archive", "archive-temperature", update.now)

{:ok, history} = Service.history(service, token, "archive", "enrollments", thing, %{}, update.now)
["3", "6"] = Enum.map(history["items"], & &1["generation"])

{:ok, %{"items" => [%{"deleted" => false, "value" => %{"query" => ^query_document}}]}} =
  Service.history(
    service,
    token,
    "archive",
    "saved_queries",
    "archive-temperature",
    %{},
    update.now
  )

{:ok, revoke} =
  Update.new(%{
    Map.from_struct(update)
    | operation_id: "revoke",
      expected_generation: "8",
      observation: nil,
      request: %{"operation" => "revoke"},
      records: [%{kind: "access", id: "archive-credential", value: %{"revoked" => true}}],
      events: [%{"type" => "access.revoked", "data" => %{}}]
  })

{:ok, %{"generation" => "9"}} = Store.mutate(store, revoke)
{:error, :unauthorized} = Store.authorized(store, access, "read", update.now)
{:error, :unauthorized} = Store.mutate(store, update)

GenServer.stop(pid)
http_directory = Path.join(directory, "http")
File.mkdir!(http_directory)
File.chmod!(http_directory, 0o700)
reader = Credentials.generate_token()
{:ok, reader_digest} = Credentials.token_digest(reader)
now = update.now

{:ok, http_credentials} =
  Credentials.new(%{
    instance_id: "archive-http",
    secret_key: :crypto.strong_rand_bytes(32),
    entries: [
      %{
        id: "admin",
        principal: "operator",
        token_sha256: digest,
        grants: %{"workshop" => ~w(read raw ingest enroll admin interact)},
        expires_at: now + 1000
      },
      %{
        id: "reader",
        principal: "reader",
        token_sha256: reader_digest,
        grants: %{"workshop" => ~w(read)},
        expires_at: now + 1000
      }
    ]
  })

{:ok, server} =
  Server.start_link(
    directory: http_directory,
    credentials: http_credentials,
    ip: {127, 0, 0, 1},
    port: 0,
    exposure: :loopback,
    public_origin: :listener,
    clock: fn -> now end,
    poll_interval: 25
  )

{:ok, {_, port}} = Server.listener_info(server)
descriptor = Path.join(directory, "http-client.json")

File.write!(
  descriptor,
  Codec.encode!(%{
    "url" => "http://127.0.0.1:#{port}",
    "token" => token,
    "reader" => reader,
    "scope" => "workshop",
    "now" => now
  })
)

File.chmod!(descriptor, 0o600)

{output, 0} =
  System.cmd(
    System.fetch_env!("WTR_HTTP_PYTHON"),
    [System.fetch_env!("WTR_HTTP_CONSUMER"), descriptor],
    stderr_to_stdout: true
  )

true = String.contains?(output, "HTTP_CONSUMER_PASS")

await_history = fn await_history, attempts ->
  case Server.operational_history(server, event: "request.stop") do
    {:ok, %{"samples" => [_ | _]}} ->
      :ok

    _ when attempts > 0 ->
      Process.sleep(10)
      await_history.(await_history, attempts - 1)

    _ ->
      raise "archive operational history did not retain an HTTP request"
  end
end

:ok = await_history.(await_history, 100)
{:ok, store_pid} = Server.child(server, :store)
origin = "http://127.0.0.1:#{port}"

{:ok, service} =
  Service.new(%{store: Store.handle(store_pid), credentials: http_credentials, base_url: origin})

{:ok, %{"items" => [%{"value" => document}]}} =
  Service.list(service, token, "workshop", "things", %{}, now)

{:ok, td} = Wotex.ThingDescription.from_map(document)
{:ok, client} = LoopbackClient.new(origin, "workshop")
{:ok, binding} = HTTP.config(client: {LoopbackClient, client})
{:ok, profile} = HTTP.profile()
{:ok, vault} = ArchivePeerCredentials.start_link(token)

{:ok, consumed} =
  ConsumedThing.new(td,
    profiles: [profile],
    transports: %{http: HTTP.transport(binding)},
    credentials: {ArchivePeerCredentials, vault}
  )

false = :erlang.term_to_binary(consumed) =~ token

context =
  Context.new!(request_id: "archive-peer", deadline: System.monotonic_time(:millisecond) + 3000)

{:ok, %Result{status: :ok, operation: :readproperty, payload: 24.3}} =
  ConsumedThing.read_property(consumed, "temperature", context)

{:ok, %Result{status: :ok, operation: :readproperty, payload: 100_044}} =
  ConsumedThing.read_property(consumed, "pressure", context)

{:ok, subscriptions} = Supervisor.start_link([], strategy: :one_for_one)

peers =
  for {name, expected} <- [{"temperature", 24.3}, {"pressure", 100_044}] do
    request_id = "observe-" <> name

    stream_context =
      Context.new!(request_id: request_id, deadline: System.monotonic_time(:millisecond) + 3000)

    {:ok, spec} =
      ConsumedThing.observation_child_spec(consumed, name, stream_context,
        id: name,
        receiver: self(),
        max_queue_length: 32,
        overflow: :stop
      )

    {:ok, subscription} =
      Supervisor.start_child(subscriptions, Supervisor.child_spec(spec, restart: :temporary))

    receive do
      {:wotex_runtime, ^name, {:ok, ^expected, meta}} ->
        :observeproperty = meta.operation
        true = String.starts_with?(meta.event, "property:snapshot:")
    after
      2000 -> raise "archive Property subscription did not deliver"
    end

    {LoopbackClient, {_, {connection, _}, _, _}, _, _} =
      subscription |> :sys.get_state() |> Map.fetch!(:handle) |> HTTP.Subscription.unwrap()

    false = :erlang.term_to_binary(:sys.get_state(connection)) =~ token
    {subscription, connection}
  end

[{first, first_connection}, {second, second_connection}] = peers
first_monitor = Process.monitor(first_connection)
:ok = Subscription.stop(first)

receive do
  {:DOWN, ^first_monitor, :process, ^first_connection, _} -> :ok
after
  1000 -> raise "first archive subscription leaked"
end

true = Process.alive?(second_connection)
second_monitor = Process.monitor(second_connection)
:ok = Subscription.stop(second)

receive do
  {:DOWN, ^second_monitor, :process, ^second_connection, _} -> :ok
after
  1000 -> raise "second archive subscription leaked"
end

Supervisor.stop(subscriptions)
GenServer.stop(vault)
Supervisor.stop(server)
File.rm_rf!(directory)
retained = Process.list() |> MapSet.new() |> MapSet.difference(before_processes) |> MapSet.size()
0 = retained

IO.puts(
  "SERVICE_COHORT_PASS durable_restart=true durable_store_forward=true atomic_transport_health=true atomic_heartbeat=true atomic_battery=true atomic_motion=true atomic_geofence=true atomic_geofence_crossing=true atomic_suspicious_movement=true analytics=true analytics_pagination=true saved_queries=true operational_telemetry=true native_types=true revoked_access_denied=true encrypted_cursor=true authenticated_enrollment_materialisation=true explicit_association=true independent_http_sse=true actual_runtime_http_peer=true actual_runtime_sse=true retained_new_processes=#{retained}"
)
