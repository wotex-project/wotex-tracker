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

The separate service package implements a bounded SQLite store with atomic
admission, historical snapshots, durable event/publication intents and recovery
tests, authenticated HTTP/OpenAPI/SSE workflows, and Runtime Property reads and
committed-value subscriptions through actual local HTTP binding peers. The
standalone CLI and bundled Darwin/Linux ARM64 service artifacts pass local probes.
See the [service contract](docs/contracts/service-v1.md). Live scanning and UI
remain subsequent work.

The WTR.05 pure foundation admits position evidence, freshness, deterministic
selection, event ordering with modular sequence evidence, and bounded geofence
membership. See the [position guide](docs/guides/positions.md) and
[geofence guide](docs/guides/geofences.md). Ordered geofence baseline, entry/exit
and edit recomputation plus bounded sparse-crossing inference are implemented;
two-fix movement/uncertainty classification is also implemented. See the
[motion guide](docs/guides/motion.md). Consecutive-segment dwell now establishes
stationary/moving state and stable trip start, stop and interruption events. Host
transactional rule persistence remains subsequent work. Bounded trip-distance
reconstruction includes only adjacent segments proved moving and reports every
exclusion. Evidence-backed heartbeat state and overdue/recovery events are also
implemented; see the [heartbeat guide](docs/guides/heartbeat.md).
Evidence-backed low-battery state uses explicit measurement kind, unit, freshness,
quality and hysteresis; see the [battery guide](docs/guides/battery.md).
[Implementation evidence](docs/evidence/implementation.md) records
executed software checks and unpassed release, host and hardware gates.

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
than reducing these requirements. No application or firmware has been built yet.

No external metrics database, vendor tracking cloud, private AI engine or hosted
build service is required to operate the deterministic product. Network bearers,
map sources, optional model providers and mobile push/distribution have explicit
host configuration and prerequisites. Sponsorship does not grant runtime access.

## License

Apache-2.0. See `LICENSE`.
