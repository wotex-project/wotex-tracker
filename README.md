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

The optional service host also implements an authorized read-only BLE GATT probe
boundary over the refactored `wotex_ble` package. Every enabled host plan must
match the same immutable profile catalogue's probe revision, characteristic and
budget ceilings; an `interact` caller cannot choose a new target. Each read runs
in a monitored worker and is cancelled on caller loss, explicit cancellation or
deadline. The host supplies and owns the upstream session. The pure resolver can
admit the resulting private evidence and recompute only the nominated passive
candidate under closed byte predicates. This is not passive scanning, peer
identity, enrollment or hardware qualification.

The service now also owns an explicitly started passive-advertisement boundary:
a host adapter returns one bounded capture at a time, monitored deadlines and
serialized admission prevent an unbounded scanner backlog, and deterministic
operation identities reconcile exact retransmissions. The standalone host has
a dev/test-only finite Ruuvi simulator composition that exercises private-address
changes through durable service state. The simulator is excluded from production
builds and is never promoted to live-radio or hardware evidence.

The pure library also contains bounded Teltonika TCP IMEI negotiation, Codec 8
Extended framing and record decoding. It validates the complete documented
frame, preserves unknown IO values and maps durable commit dispositions to
explicit ACK-or-close decisions. Documentation-qualified TAT140 and ATC700
profiles share one closed record pipeline while retaining distinct immutable
revisions. Both map documented movement, battery voltage and valid GNSS fixes;
ATC700 additionally maps its documented battery-level IO. Every record and
unsupported IO value remains preserved. This is not hardware qualification. See the
[Codec 8 Extended guide](docs/guides/teltonika-codec8-extended.md).
The service package adds explicitly started, serialized cellular admission:
configured keyed IMEI lookup, exact raw-frame observation custody, deterministic
retransmission receipts and commit-dependent ACK dispositions. Its optional
bounded TCP server owns explicit login/frame deadlines and a finite connection
budget; an independent Erlang peer exercises the real wire across every login
and fixture-frame split. A configured device may bind its profile marker into
the durable observation for exact later resolution; generic devices retain an
explicit null marker. The record-aware decoder atomically persists every ordered
semantic record and private claim. Its atomic batch receipt gives each record a
stable operation identity and explicit disposition. None of these slices is
hardware qualification.

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
The standalone and Nerves hosts can also admit a separate private APNs provider/
dispatcher document, supervise that delivery worker and report the composition
explicitly as configured or unconfigured. The bundled-release probe requires
that configured capability and rejects provider-key log disclosure. Provider
acceptance, OS delivery and a user tap remain separate unpassed gates.
See the [service contract](docs/contracts/service-v1.md). The first shared browser
workflow now covers sign-in, bounded JSON capture import, evidence review,
enrollment, later observation association, provisioning, retained measurements
and positions, retained state history, gap-honest route pages and a structured
per-asset analytics table.
Position-capable state appears on overview and asset screens with source,
uncertainty, clock and quality disclosures; the UI does not imply a live, fused or
canonical location. Route history now includes a bounded interactive
retained-position map with keyboard-operable pan and zoom controls plus bounded
latitude/longitude graticules while keeping exact coordinates, exclusions and
gaps visible. Antimeridian labels return to the ordinary longitude range. An
optional bounded, attributed [offline map pack](docs/contracts/map-pack-v1.md)
can supply operator-controlled road, water and boundary context on the browser,
Pi and mobile hosts without a map network request. A page outside complete pack
coverage draws no partial background. Context never road-matches or invents a
position. Live scanning and physical cross-surface qualification remain
subsequent work.

The independent mobile host now pins its OTP 29 / Elixir 1.20.1 Mob runtime
cohort without changing the root library's Elixir floor. Its first executable
boundary is a private SQLite
cache for bounded overview, history, dashboard and map projections. Cache reads
identify offline source, synchronization age and completeness; exact server,
account, scope, credential and installation changes, credential expiry and
sign-out purge retained data. Credentials, raw evidence, pending mutations and
physical Actions are not cache entries. A loopback-only Phoenix endpoint now
serves the shared UI inside one Mob WebView, requires an ephemeral app-session
capability, retains that binding across browser-session renewal and rejects
foreign WebSocket origins. Remote requests use the selected HTTPS authority
after the mobile OS resolver seam, and external HTTPS navigation leaves the
bridge-bearing WebView. An iOS Mob plugin now supplies two closed,
device-only Keychain slots without a file fallback; credential/cache lifecycle
wiring and closed native lifecycle, BLE-central, push-registration/tap-routing
and share bridges are implemented in software. The committed native iOS tree
boots that composition, and first launch selects an exact operator-controlled
HTTPS service without developer tooling while keeping session secrets
ephemeral. Physical secure-storage, suspend/resume, BLE, push/tap and share
acceptance on a signed device, plus distribution gates, remain open.

A first-class integrated development scenario now drives one durable simulated
tracker through the remote web client, the local Pi client, the mobile native
capability/cache composition and an independent Rust HTTP consumer. It admits
passive data, enrolls and materialises the Thing, restarts the actual service,
disconnects and reconnects the mobile network, revokes the shared reader and
replays duplicate ingress across restart. The scenario requires durable history,
one admitted observation, one generation advance and no physical Action intent.
It is complete local software evidence; physical radios, Pi display/touch, a
signed iPhone, live providers and distribution retain their separate acceptance.

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
It also pages each Thing's retained trip start, stop and interruption alerts at
an independently snapshot-pinned boundary, so unrelated alerts cannot consume a
trip-history page. A separate authorized operation reconstructs a completed
trip from at most 100 retained position materialisations using the exact motion
policy active at trip start. It publishes bounded centre/lower/upper distance
and every included or excluded segment, while incomplete, ambiguous or
noncanonical cohorts fail without exposing private evidence identities.
Administrators can persist complete motion and geofence definitions for enrolled
Things, plus an event-only suspicious-movement definition that privately binds
one exact motion policy for the same Thing. Later materialisations evaluate the
stateful definitions atomically when the evidence bundle
contains exactly one position, without silently selecting among sources.
The shared browser can create and exactly edit those ordering, threshold, dwell,
uncertainty and circle/polygon geometry policies while making that single-source
requirement explicit.
It also presents retained trip starts, stops and interruptions inside a selected
half-open UTC window. The default covers the 30 days ending immediately after
the latest retained state; fixed-offset timezone and exact millisecond/second
interval controls change presentation without changing the service records.
The browser pairs endpoints only when both occur on the displayed snapshot page
and reauthorizes each cursor-free page export with its window and presentation
metadata. Each stop or interruption links to the service-reconstructed final
distance: exact centre/lower/upper metres, complete or partial status and every
included or excluded adjacent segment. The dedicated screen validates the
closed public projection, retains a valid result across temporary failures and
reauthorizes a bounded identity-matched JSON export. Readers may present times
at a closed fixed UTC offset and distance in metres, kilometres or international
miles. Converted distance is visibly rounded for display only; canonical service
metres and the exact presentation choices remain in the export.
Evidence-backed heartbeat state and overdue/recovery events are also
implemented; see the [heartbeat guide](docs/guides/heartbeat.md).
Its SQLite host integration persists changed heartbeat state and event intent
atomically. The explicitly supervised rule scheduler reconstructs persisted
heartbeat deadlines on startup and commits due live evaluations without
dispatching a physical Action.
Evidence-backed low-battery state uses explicit measurement kind, unit, freshness,
quality and hysteresis; its SQLite host integration atomically persists changed
state and stable event intent. See the [battery guide](docs/guides/battery.md).
The suspicious-movement rule combines confirmed motion, armed state and explicit
owner-presence facts with three-valued logic; see the
[policy guide](docs/guides/suspicious-movement.md). The service now commits an
administrator's explicit armed/disarmed fact for an enrolled Thing, retains its
closed private evidence and exposes only a reviewed public state; it does not
claim device contact. It also admits complete exact or strong owner-presence
facts without treating missing radio evidence as absence, retaining their closed
inputs while exposing only present, absent or unknown state. Saving the event-only
definition, changing either fact, or materialising a new motion state evaluates
every exact live binding and atomically records any stable suspicious-movement
intent and reviewed alert without manufacturing rule state. The shared browser distinguishes
unknown, unsupported, armed and disarmed state and uses confirmed, recoverable
administrator operations for changes.
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
terminal-denial behavior. Compatible saved definitions can be composed into a
multi-series dashboard, and every saved dashboard exposes a credential-free
relative link that still requires the recipient's current same-scope authority.
An optional bounded prompt adapter proposes the same closed query form. A
dev/test-only Responses peer now exercises its complete schema-only request,
closed query or clarification response, limits and malicious-boundary handling
without resolving a hostname. A recorded real public-provider prompt run and
physical cross-surface acceptance remain open.

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
- **Teltonika ATC700** — compact rechargeable cellular tracker with a distinct
  documentation-fixture profile and direct operator-server configuration path;
  physical qualification remains open.
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

The maintained [abuse analysis](docs/security/abuse-analysis.md) records the
dual-use and anti-stalking threats, implemented software controls and remaining
physical gates. The shared application exposes the same core limitations at
`/safety` without requiring an account. Neither the analysis nor the current
software claims phone-vendor-scale unwanted-tracker detection.

No external metrics database, vendor tracking cloud, private AI engine or hosted
build service is required to operate the deterministic product. Network bearers,
map sources, optional model providers and mobile push/distribution have explicit
host configuration and prerequisites. Sponsorship does not grant runtime access.

## License

Apache-2.0. See `LICENSE`.
