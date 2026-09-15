# Runs from an isolated production consumer, using only installed archive files.
alias Wotex.Tracker
alias Wotex.Tracker.{Deployment, Evidence, EvidenceBundle, Identity, Model}
alias Wotex.Tracker.Decoders.RuuviRawV2

[] = Application.spec(:wotex_tracker, :mod)

for module <- [Phoenix, Wotex.Directory, Nx, Nerves] do
  false = Code.ensure_loaded?(module)
end

false = :wotex_runtime in Application.spec(:wotex_tracker, :applications)

if is_nil(Application.spec(:wotex_tracker_service)),
  do: false = Code.ensure_loaded?(Wotex.Runtime)

{:ok, document} =
  Wotex.JSON.decode(
    File.read!(
      Application.app_dir(
        :wotex_tracker,
        "priv/thing_models/environmental-sensor-1.0.0.tm.json"
      )
    )
  )

{:ok, profile} = RuuviRawV2.profile()
{:ok, catalogue} = Tracker.catalogue([profile])

{:ok, observation} =
  Tracker.observation(%{
    id: "archive-fixture",
    observed_at: 1_700_000_000_000,
    ingress: "ble",
    source: %{"receiver_id" => "archive-consumer"},
    addressing: %{},
    radio: %{},
    transport: %{"manufacturer_id" => 1177},
    provenance: %{"kind" => "fixture", "source" => "ruuvi-documentation"},
    payload: {:bytes, Base.decode16!("0512FC5394C37C0004FFFC040CAC364200CDCBB8334C884F")}
  })

before_processes = MapSet.new(Process.list())

{:ok, imported} =
  Tracker.import_observation(
    observation,
    catalogue,
    {RuuviRawV2.revision(), &RuuviRawV2.decode/1}
  )

thing_id = "urn:uuid:aca49b80-1e09-40cf-929e-b193047f6ca9"

{:ok, association} =
  Evidence.new(%{
    id: "operator-association",
    kind: :identity,
    claim: %{"thing_id" => thing_id, "strategy" => "operator-pseudonym-v1", "revision" => "1"},
    source_observation_ids: [observation.id],
    evidence_ids: [],
    profile: {profile.id, profile.version},
    decoder: profile.decoder,
    confidence: :exact,
    reasons: ["synthetic_operator_fixture"],
    association_id: "enrollment-1"
  })

{:ok, bundle} =
  EvidenceBundle.new([observation], [association | Map.values(imported.decoded.bundle.evidence)])

{:ok, identity} =
  Identity.new(
    %{
      thing_id: thing_id,
      association_id: "enrollment-1",
      revision: "1",
      evidence_id: association.id
    },
    bundle
  )

{:ok, model} = Model.new(document, profile.model)

forms =
  Map.new(profile.mapping, fn {name, pointer} ->
    {pointer,
     [
       %{
         "href" => "https://operator.example.invalid/properties/" <> name,
         "op" => "readproperty",
         "contentType" => "application/json"
       }
     ]}
  end)

{:ok, deployment} =
  Deployment.new(%{
    revision: "fixture-deployment",
    title: "Archive fixture sensor",
    forms: forms,
    security_definitions: %{"token" => %{"scheme" => "bearer"}},
    security: ["token"]
  })

{:ok, materialised} =
  Tracker.materialize(%{
    observation: observation,
    catalogue: catalogue,
    resolution: imported.resolution,
    decoded: imported.decoded,
    bundle: bundle,
    capabilities: imported.decoded.capabilities,
    identity: identity,
    model: model,
    mapping_revision: profile.mapping_revision,
    deployment: deployment
  })

td = Wotex.ThingDescription.to_map(materialised.td)
^thing_id = td["id"]
10 = map_size(td["properties"])
"Cel" = td["properties"]["temperature"]["unit"]
{:ok, encoded} = Wotex.ThingDescription.encode(materialised.td, :canonical)
false = String.contains?(encoded, "cbb8334c884f")
true = MapSet.subset?(MapSet.new(Process.list()), before_processes)
{:ok, empty} = Tracker.catalogue([])

{:ok, %{decoded: nil, resolution: %{status: :unknown}}} =
  Tracker.import_observation(observation, empty, :absent)

# Independent synthetic position evidence; no GPS capability is attributed to Ruuvi.
{:ok, capture} =
  Tracker.observation(%{
    id: "synthetic-position",
    observed_at: 1000,
    ingress: "imported",
    source: %{},
    addressing: %{},
    radio: %{},
    transport: %{},
    provenance: %{"kind" => "synthetic-fixture"},
    payload: {:json, %{"latitude" => 0, "longitude" => 0.0}}
  })

{:ok, claim} =
  Evidence.new(%{
    id: "position-claim",
    kind: :position,
    source_observation_ids: [capture.id],
    evidence_ids: [],
    profile: {"synthetic-position", "1"},
    decoder: {"synthetic-position", "1"},
    confidence: :exact,
    reasons: ["synthetic_fixture"],
    association_id: nil,
    claim: %{
      "schema" => "wtr.position.v1",
      "latitude" => 0,
      "longitude" => 0.0,
      "altitude_m" => nil,
      "speed_m_s" => 0.0,
      "horizontal_accuracy_m" => nil,
      "accuracy_kind" => "unknown",
      "source" => "operator",
      "fix_at" => 900,
      "device_at" => nil,
      "received_at" => 1000,
      "fix_clock" => "trusted",
      "device_clock" => "unknown",
      "availability" => "available",
      "quality" => "valid",
      "receiver_observation_id" => capture.id,
      "source_units" => %{
        "latitude" => "degree",
        "longitude" => "degree",
        "altitude" => nil,
        "speed" => "m/s",
        "accuracy" => nil,
        "fix_time" => "unix-ms",
        "device_time" => nil,
        "receiver_time" => "unix-ms"
      },
      "raw" => %{},
      "conversion_revision" => "identity-v1"
    }
  })

{:ok, positions} = EvidenceBundle.new([capture], [claim])
{:ok, position} = Wotex.Tracker.Position.new(claim.id, positions)
{:ok, exported} = Wotex.Tracker.Position.to_map(position, positions)
0 = exported["position"]["latitude"]
true = exported["position"]["longitude"] === 0.0

{:ok, policy} =
  Wotex.Tracker.PositionFreshness.new(%{
    revision: "archive-clock-v1",
    max_age_ms: 10,
    future_skew_ms: 0,
    missing_fix: :receiver_time,
    accept_suspect: false
  })

{:ok, %{"status" => "stale", "time_basis" => "fix", "age_ms" => 100}} =
  Wotex.Tracker.PositionFreshness.evaluate(position, positions, policy, 1000)

{:ok, selection_policy} =
  Wotex.Tracker.PositionSelection.new(%{
    revision: "archive-selection-v1",
    accepted_freshness: [:stale],
    source_priority: [:operator],
    unlisted_sources: :reject,
    missing_accuracy: :last,
    max_horizontal_accuracy_m: nil
  })

{:ok, %{"status" => "selected", "selected" => %{"evidence_id" => "position-claim"}}} =
  Wotex.Tracker.PositionSelection.select(
    [%{position: position, bundle: positions}],
    selection_policy,
    policy,
    1000
  )

{:ok, fence} =
  Wotex.Tracker.Geofence.new(%{
    id: "archive-yard",
    revision: "archive-fence-v1",
    shape: %{kind: :circle, latitude: 0, longitude: 0, radius_m: 1},
    boundary: :inside,
    uncertainty: :coordinate_only
  })

{:ok, %{"status" => "inside", "algorithm" => "wgs84-authalic-haversine-v1"}} =
  Wotex.Tracker.Geofence.evaluate(fence, position, positions)

{:ok, sample} = Wotex.Tracker.PositionSample.new(position, positions)

{:ok, order_policy} =
  Wotex.Tracker.PositionOrder.new(%{
    revision: "archive-order-v1",
    event_time: :trusted_fix,
    future_skew_ms: 0,
    late_window_ms: 1_000,
    sequence: :none
  })

{:ok, %{"status" => "accepted", "disposition" => "advance"}} =
  Wotex.Tracker.PositionOrder.evaluate(sample, nil, order_policy, 1_000)

{:ok, transition_policy} =
  Wotex.Tracker.GeofenceTransition.new(%{
    id: "archive-yard-membership",
    revision: "archive-transition-v1",
    order_policy: order_policy,
    max_transition_gap_ms: 1_000
  })

{:ok, %{"status" => "baseline", "event" => nil, "state" => transition_state}} =
  Wotex.Tracker.GeofenceTransition.evaluate(
    nil,
    fence,
    sample,
    transition_policy,
    :replay,
    1_000
  )

{:ok, ^transition_state} =
  Wotex.Tracker.GeofenceTransition.validate_state(transition_state)

true = MapSet.subset?(MapSet.new(Process.list()), before_processes)

IO.puts(
  "SOURCE_COHORT_PASS Elixir=#{System.version()} OTP=#{System.otp_release()} properties=10 position_freshness=true position_selection=true position_order=true geofence=true geofence_transition=true no_new_processes=true optional_hosts_absent=true"
)
