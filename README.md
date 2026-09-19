# Wotex Tracker

**Your trackers. Your infrastructure.**

WoTEx Tracker specifies a complete physical asset-tracking product with an
Elixir/OTP engine, a shared LiveView application, a Pi 5 control panel and an
iPhone companion. The smart-bike application and third-party headless consumers
use the same tracking contracts. Its reusable `wotex_tracker` library turns
heterogeneous trackers and sensors into evidence-backed W3C Web of Things Things.

The target design is hardware- and transport-agnostic. A physical device may first appear as a BLE advertisement, a cellular tracker connection, a LoRaWAN uplink, MQTT data, HTTP data, or another bounded ingress. The planned pipeline preserves observations as evidence, resolves a versioned device profile deterministically, decodes only what that profile proves, and materialises an instance Thing Description from a Thing Model. Explicit host integrations will expose the resulting Thing through ordinary WoT interfaces.

```text
physical device
      |
      v
bounded observation
      |
      v
fingerprint -> device profile -> decoder -> capability evidence
                                      |
                                      v
                              Thing Model + identity
                                      |
                                      v
                              Thing Description
                                      |
                         +------------+------------+
                         |                         |
                    Wotex Runtime             Directory
                         |
                    HTTP / MQTT / ...
```

## Status

This repository starts from **accepted target specifications**. Specification presence, fixtures, examples, or catalogue entries do not imply implementation, hardware qualification, interoperability, or W3C conformance. Executed evidence is tracked separately from target contracts.

The pure imported-fixture-to-TD pipeline is implemented: bounded observations,
immutable profiles, deterministic resolution, Ruuvi RAWv2 decoding, capability and
identity evidence, a packaged environmental model, and upstream-validated Thing
Descriptions. The library has a complete local verification gate and explicit
archive packaging. Start with the [pipeline guide](docs/guides/materialisation.md).
Trusted profile callbacks may also return bounded normalized position claims;
the decoder wrapper binds each claim to its exact observation, catalogue,
profile and decoder revisions. The built-in Ruuvi RAWv2 profile remains
explicitly positionless.

The service accepts an exact host-configured catalogue/model/decoder set as an
alternative to its packaged Ruuvi defaults. Position-capable decoder output is
committed with private evidence and a closed redacted public-state projection;
raw source fields and receiver lineage remain available only through authorized
raw evidence export.

The separate service package implements a bounded SQLite store with atomic
admission, historical snapshots, durable event/publication intents and recovery
tests, bounded durable store-and-forward, authenticated HTTP/OpenAPI/SSE
workflows, and Runtime Property reads and
committed-value subscriptions through actual local HTTP binding peers. Its
privileged host port also atomically persists transport-health state and stable
event intents plus heartbeat, low-battery, motion/trip and geofence state and
intents, with restart recovery and retry deduplication. The
standalone CLI and bundled Darwin/Linux ARM64 service artifacts pass local probes.
See the [service contract](docs/contracts/service-v1.md). The first shared browser
workflow now covers sign-in, bounded JSON capture import, evidence review,
enrollment, later observation association, provisioning, retained measurements
and positions, retained state history, gap-honest route pages and a structured
per-asset analytics table.
Position-capable state appears on overview and asset screens with source,
uncertainty, clock and quality disclosures; the UI does not imply a live, fused or
canonical location. Live scanning, maps and the rest of the application remain
subsequent work.

The WTR.05 pure foundation admits position evidence, freshness, deterministic
selection, event ordering with modular sequence evidence, and bounded geofence
membership. See the [position guide](docs/guides/positions.md) and
[geofence guide](docs/guides/geofences.md). Ordered geofence baseline, entry/exit
and edit recomputation plus bounded sparse-crossing inference are implemented.
Changed geofence state and stable event intent can be committed atomically and
restored after restart; inferred-crossing event intents have an event-only atomic
deduplication path, as do suspicious-movement alarms over durable motion state and
evidence-backed armed/owner facts;
two-fix movement/uncertainty classification is also implemented. See the
[motion guide](docs/guides/motion.md). Consecutive-segment dwell now establishes
stationary/moving state and stable trip start, stop and interruption events. Host
transactions now persist changed motion state and stable trip event intent
atomically. Bounded trip-distance reconstruction includes only adjacent segments
proved moving and reports every exclusion. Bounded route replay orders exact
position samples and starts a new segment after rejected evidence or an excessive
time/distance gap; it never invents a path across missing history.
The service exposes that replay as snapshot-pinned retained-route pages under
current read authority. It reconstructs complete samples only inside the private
boundary, pseudonymizes public point/rejection identities and turns missing or
ambiguous position materialisations into explicit segment breaks.
Administrators can persist complete motion and geofence definitions for enrolled
Things; later materialisations evaluate them atomically when the evidence bundle
contains exactly one position, without silently selecting among sources.
The shared browser can create and exactly edit those ordering, threshold, dwell,
uncertainty and circle/polygon geometry policies while making that single-source
requirement explicit.
Evidence-backed heartbeat state and overdue/recovery events are also
implemented; see the [heartbeat guide](docs/guides/heartbeat.md).
Its SQLite host integration persists changed heartbeat state and event intent
atomically; deadline scheduling remains explicit host work.
Evidence-backed low-battery state uses explicit measurement kind, unit, freshness,
quality and hysteresis; its SQLite host integration atomically persists changed
state and stable event intent. See the [battery guide](docs/guides/battery.md).
The suspicious-movement rule combines confirmed motion, armed state and explicit
owner-presence facts with three-valued logic; see the
[policy guide](docs/guides/suspicious-movement.md).
Evidence-qualified transport selection keeps bearer, application protocol,
budgets and acknowledgement layers explicit; see the
[transport policy guide](docs/guides/transport-policy.md). A pure transport
health rule classifies declared primary routes, fallbacks, no-route outcomes and
uncertain acknowledgements, with stable degradation and recovery events. Its
first SQLite host integration persists those transitions atomically.
[Implementation evidence](docs/evidence/implementation.md) records
executed software checks and unpassed release, host and hardware gates.

The analytics core admits content-identified numeric history rows and closed
absolute-UTC queries, then deterministically returns bounded bucketed
count/min/max/mean/last series with snapshot binding, stable ties, preserved gaps
and disclosed exclusions. The service now authorizes those queries, extracts
committed SQLite state history in one pinned snapshot and exposes the closed
query/result contract over HTTP with bounded per-principal execution and
cancellation. Administrators can also persist fixed-window query definitions
and closed visualization options, retain their version/tombstone history and
execute them later under current read authority. See the
[analytics guide](docs/guides/analytics.md).
The shared browser can submit an absolute UTC numeric query for one provisioned
asset and inspect qualified buckets, source gaps, counts and snapshot identity.
It offers line, area and point graphs with separate paths across gaps, an exact
table and time-window navigation. The browser can list and rerun saved query
definitions under current read authority, and an administrator can save the
current graph as a fixed, rolling or incident-snapshot definition, edit or
delete it, and combine compatible definitions. Open saved dashboards and the
unsaved analytics page can follow committed changes with explicit stale and
terminal-denial behavior. An optional bounded prompt adapter proposes the same
closed query form. General dashboard composition and sharing, a recorded real
public-provider prompt run and physical cross-surface acceptance remain open.

The service package also defines closed `:telemetry` events for requests,
queries, import stages, commits, forward queues, publication reconciliation and
store health. An explicitly supervised collector gives the default HTTP host a
bounded volatile ETS history with a restart epoch; loading either library
installs no handler and starts no process. An enabled administrator view plots
closed measurements over pinned one-, five- or fifteen-minute windows with
elapsed-time spacing, disclosed projection limits and exact table pages. Hosts
may explicitly add the bounded asynchronous exporter boundary; no remote metrics
service starts by default.

Start with the [WTR specification index](docs/specs/WTR-index.md) and the [software implementation sequence](docs/plans/software-implementation.md).

The dated [ecosystem research](docs/provenance/ecosystem-research.md) records
Nerves/Nx/library candidates, related tracker patterns and unresolved qualification.
The [specification readiness review](docs/provenance/spec-readiness-review.md)
records findings, resolutions, executed checks and remaining limitations.

## Design rules

- **Stable library, complete application.** Required service, web, Pi and mobile deliverables remain optional installations. The reusable service and machine interfaces are authoritative; every frontend is a consumer.
- **Shared UI.** LiveView/HEEx screens power the web app, local Pi kiosk and native mobile WebView. Native bridges provide device capabilities without duplicating tracking policy.
- **Usable without Elixir.** A bundled service release/container exposes versioned HTTP/JSON and resumable events for other languages and frontends.
- **Interactive analytics.** Dynamic graphs, history queries and saved dashboards are required. Prompted queries are validated and executed by the service; AI remains explicitly configured and optional to operation.
- **Evidence before inference.** Device identity and capabilities come from deterministic protocol evidence, not AI guesses.
- **No vendor-cloud dependency.** A supported hardware profile must have a documented path to infrastructure controlled by the operator. Vendor SaaS may be optional but never mandatory.
- **Transport is not semantics.** BLE, LTE-M/NB-IoT/Cat-1, LoRaWAN, Wi-Fi, MQTT, HTTP, and vendor wire protocols are ingress or interaction mechanisms. Applications consume WoT Properties, Actions, and Events.
- **LoRaWAN is optional.** A device profile may use it, but the architecture does not require it.
- **AI is optional.** Refpath is private, under development and disabled by default. An optional showcase may demonstrate validated Things and governed proposals, but tracking, discovery, decoding, rules, alarms and Thing materialisation work without it.
- **Safe by default.** Unknown devices stay unknown. Ambiguous matches are not auto-admitted. Physical Actions require stronger evidence and authorization than read-only Properties.

## Initial proof matrix

The first profiles are intended to prove different topologies rather than one preferred vendor:

- **RuuviTag** — passive BLE advertisement discovery and environmental sensing using an openly documented wire format.
- **Teltonika TAT140** — finished rugged cellular asset tracker sending directly to an operator-controlled server.
- **Teltonika ATC700** — compact rechargeable cellular tracker using the same semantic asset-tracker model through a different profile.
- **LoRaWAN** — optional later profile/ingress lane, only for hardware and network paths that pass the project's no-vendor-lock gate.

Hardware names in specifications are qualification targets, not architectural dependencies.

## WoTEx boundaries

`wotex_tracker` consumes the WoTEx ecosystem rather than replacing it:

- `wotex` owns TD/TM/DataSchema/Form values and validation.
- `wotex_runtime` owns portable ConsumedThing/ExposedThing interaction planning and ports.
- `wotex_ble` owns generic BLE/GATT values and WoT mapping. Passive advertisement ingestion is a separate capability to qualify; GATT discovery does not prove scanner availability.
- `wotex_directory` owns Thing Description Directory semantics.
- protocol bindings such as HTTP and MQTT own WoT Form-to-protocol mapping.
- `wotex_continuum` defines inert exchange values; the host supplies any edge/cloud transport.
- `wotex_nx` optionally converts typed observations to numerical inputs and inert outputs; Tracker/its consumer owns any fusion algorithm.
- `wotex_conformance` can evaluate exact artifacts through an external adapter; it is not a production dependency or a hardware qualification authority.
- `wotex_lab` may optionally be used for experiments. Tracker owns its acceptance tests and qualification evidence and must work with Lab absent.
- Refpath is an optional AI/agent consumer of validated WoT affordances.

Core WoTEx packages must never depend on `wotex_tracker`.

## Required product deliverables

The [application contract](docs/specs/WTR.15-product-and-mobile-applications.md)
requires enrollment, live/last-known position, battery/connectivity, map and trip
history, protection rules, alerts, privacy controls and offline/reconnect behavior.
[Analytics](docs/specs/WTR.16-metrics-and-prompted-analytics.md) includes prompted
queries, interactive graphs and saved dashboards over authorized data.

The [service](docs/specs/WTR.07-headless-interfaces.md) ships independently of UI.
The [Nerves Pi 5 application](docs/specs/WTR.14-nerves-and-liveview-hosts.md)
provides headless and local touch-display profiles. The mobile companion shares
the web UI and adds secure storage, notifications and qualified local BLE support.
Each host owns startup and resources; the library remains inert. Framework gaps,
missing hardware evidence or distribution funding block the relevant gate rather
than reducing these requirements. The first browser workflow is implemented;
complete application and firmware acceptance remain open.

No external metrics database, vendor tracking cloud, private AI engine or hosted
build service is required to operate the deterministic product. Network bearers,
map sources, optional model providers and mobile push/distribution have explicit
host configuration and prerequisites. Sponsorship does not grant runtime access.

## License

Apache-2.0. See `LICENSE`.
