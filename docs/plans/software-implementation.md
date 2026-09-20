# Software implementation sequence

This plan orders accepted work by executable dependency. The Phase 0–2 pure software implementation is present; the public-release consumer
gate remains unpassed. Service, rule and analytics foundations are present, and
the first shared browser workflow is implemented. The current executed scope and unpassed
gates are recorded in [implementation evidence](../evidence/implementation.md).
The milestones below remain target acceptance criteria; their presence does not
claim implementation or hardware qualification. [WTR.13](../specs/WTR.13-elixir-otp-and-verification.md)
applies from the first line of code.

Required product gates cannot be demoted to optional work to fit a dependency's
current capabilities. A software milestone can pass independently; full product
acceptance requires every required delivery target in the catalogue. Missing
hardware, funding or upstream implementation is an unpassed gate, not a waiver.

## Dependency and repository layout

Use a normal root Mix library with `lib/wotex/tracker/`, `test/`, packaged
`priv/thing_models/` and versioned fixture provenance. Only `wotex` is required
by the first pure milestone. Do not create placeholder modules for future work.

Independent host Mix projects own application callbacks, configuration, storage,
network clients and supervision. WTR.15 fixes `packages/tracker_service/` for
explicit service components, `packages/tracker_ui/` for shared LiveView/HEEx,
`hosts/app/` for the server/release, `hosts/nerves/` for firmware, and
`hosts/mobile/` for the local mobile runtime/native shell. Introduce each project
with its implemented milestone. No host starts another host's application tree;
the root archive excludes all hosts and shared application packages.

No Tracker dependency on Lab, Refpath, private source or an unreleased optional
protocol package is needed for the pure path. WTR.10 records existing ecosystem
owners and required host solution boundaries. The [source cohort](../provenance/primary-sources.md)
and [dated research](../provenance/ecosystem-research.md) record inspected sources;
neither installs dependencies nor proves compatibility or hardware acceptance.
Coordinated source development resolves WoTEx packages from the sibling monorepo's
`packages/` directory; the monorepo root is tooling and is never a package
dependency.

Phase numbers identify milestones, not a requirement to wait for unrelated
hardware or optional integrations. This table controls implementation ordering:

| Phase | Executable prerequisites | Required for complete product |
|---|---|---|
| 0 Foundation | None | Yes |
| 1 Admission/decoder | 0 | Yes |
| 2 Materialisation | 1 | Yes |
| 3 Service/API/durable store | 2 | Yes |
| 4 Passive BLE | 3 and exact upstream scanner contract | Yes |
| 5 Direct cellular | 3 and exact device/protocol contract | Yes |
| 6 Tracking rules | 3; fixtures first, qualified inputs for physical acceptance | Yes |
| 7 LoRaWAN | 3, 6 and selected hardware/network | No; required if offered |
| 8 Pi service/control panel | 3; shared screens from 10 | Yes |
| 9 Refpath showcase | 3 and WTR.11 connector contract | No; private and off by default |
| 10 Shared application | 3; rule workflows from 6 | Yes |
| 11 Mobile companion | 3, shared screens from 10 and selected native bridges | Yes |
| 12 Interactive/prompted analytics | 3, 6 and shared UI infrastructure from 10 | Yes |
| 13 Integrated product | 4, 5, 6, 8, 10, 11, 12 | Yes |

UI implementation can begin after the service using admitted fixtures. Its full
workflow acceptance includes Phase 12 analytics and the physical Pi/mobile gates.
This is an integration requirement, not a circular build dependency. Optional
phases do not block unrelated work.

## Phase 0 — package and verification foundation

Create the Mix library, formatter, test helper, LICENSE/NOTICE, contribution and
security guidance and explicit package file list. Declare WTR.13's runtime floor
and exact verification lanes. Do not manually write generated release history.
GitHub workflows/action pins/topology and release automation require separate
authority and are not changed by this plan.

Implement catalogue validation, local documentation/spec-link checks and an
explicit complete local gate. Reject duplicate IDs/keys, missing files, unresolved
references, invalid statuses and evidence promotion without evidence records.
Validate required delivery targets and their prerequisite graph separately from
contract-reference edges and optional dependency installation.

Acceptance: clean compile with warnings as errors, full configured gate,
documentation build and inspected archive. An isolated consumer starts no Tracker
process and imports no optional host/runtime code. Missing available upstream
releases are reported without overriding constraints. Development paths use
`WOTEX_PATH_DEPS=1` only under WTR.10. A fixture pipeline is not yet claimed.

## Phase 1 — observation, resolution and Ruuvi decoder

Implement admitted Observation/Evidence/Profile/Capability/Resolution/Error
values, immutable catalogue input, declarative matching and explicit identity
association. Then implement the pure RAWv2 decoder before materialisation.

Acceptance: exact/unknown/ambiguous/candidate-only inputs; catalogue permutations
and conflicts; complete lineage and identity collision cases; malformed/oversized
JSON and bytes; unavailable/mixed/zero values; source-derived ordinary and extreme
Ruuvi vectors. False/zero and numeric types survive serialization unchanged.
Changing any identity-relevant field breaks identity equality. No process, clock
read, hardware, persistence or wire-selected callback module is involved.

Pin source snapshots, profile/decoder versions and units with fixture expectations.
Documentation vectors are not real-device captures. Preserve raw evidence and
quality without inventing movement state or battery percentage.

## Phase 2 — self-contained model and materialisation

Implement one environmental-sensor TM and explicit capability mapping under
WTR.04. Use upstream model/TD constructors and JSON admission. Pass explicit
pseudonymous identity, security and deployment Forms. No model network resolver,
general inheritance engine or templating language is included.

Acceptance: fixture -> observation -> resolution -> decoder evidence -> capabilities
-> TM selection -> validated TD, with fixed canonical output and no Tracker-created
processes. Exercise every WTR.04 failure case and retained provenance. Unsupported
affordances are absent; missing mandatory capability/Form/security fails explicitly.

This completes only the first pure software milestone. Synthetic Forms do not
prove a reachable endpoint. This milestone excludes live scanning, Runtime,
Directory, databases, CLI/server/UI, cellular listeners, firmware, LoRaWAN and AI.

## Phase 3 — service, machine API, durable store and Runtime proof

The durable SQLite foundation is implemented in `packages/tracker_service/`;
the authenticated import/enrollment/materialisation facade is implemented.
The privileged transaction port atomically persists transport-health, heartbeat,
low-battery, motion/trip and geofence state with stable event intents and restart
restoration.
The bounded HTTP/OpenAPI/SSE foundation, public resource history and Runtime
Property reads and committed-value subscriptions are implemented. The standalone host startup and HTTP CLI are
implemented and tested from source and bundled artifacts. Darwin ARM64 releases
and Linux ARM64 OCI pass their local lifecycle probes, including CLI Property
resume and actual Runtime HTTP-binding subscriptions from production archives.
The optional UI composition now supports source-tested enrollment and asset
inspection. Its local UI package consumers and Darwin/Linux bundled artifacts
pass the first browser lifecycle probe. Later rule/analytics workflows remain
required. See
[executed evidence](../evidence/implementation.md).

Add the explicitly started shared service, server host and CLI using imported
observations first. Introduce only the real host's needed discovery/state/clock
ports. Volatile per-instance state is an early development substep only. Consume
Runtime ExposedThing/ConsumedThing APIs with host-owned handlers, credentials,
transport and an actual client through the HTTP or MQTT binding. A binding does
not supply an HTTP server or MQTT broker/client.

Implement the foundational WTR.07 HTTP/JSON/OpenAPI/SSE resources and WTR.06
durable local SQLite storage. Rule-specific and analytics operations are completed
with Phases 6 and 12, through this same interface. They remain required for the
full service/product; early foundation acceptance must state its smaller scope.
Fix driver/schema, transactions, commit outcomes, retention, migrations, backup
and crash recovery before persistence code. Ship service-only and UI-enabled
compositions; Phoenix is not needed by the machine API.

Acceptance: a fixture-generated TD drives a real local software-peer Property
read and a subscription where the selected binding implements it. Test two
independent instances, authorization, unavailable values, unsupported Forms and
teardown. Directory registration is a separately configured integration.

Additionally test snapshot-to-stream continuity, cursor expiry, re-authorization,
scoped idempotency, operation-status lookup, conditional writes and failure
injection across commit/publication/cleanup. Build a bundled release and OCI image
for declared architectures; exercise them with an independently executed
protocol client that imports no production domain modules. The bundled host may
use its own ERTS and must require no external BEAM toolchain. Repository clients,
generators, consumers, build orchestration and images contain no Python. No
external database server, AI provider, Lab or UI is required for this service
gate.

## Phase 4 — passive BLE hardware proof

Fix the public scanning adapter and WTR.13 lifecycle budgets before implementation.
The existing `wotex_ble` owns generic BLE/GATT. GATT discovery is not a passive
scanner, and its accepted native backend target is not assumed finished. Missing
upstream work remains explicit and must pass its own acceptance.

Qualify one OS/controller/backend lane at a time. Linux, macOS and Nerves/Pi 5
are separate claims. Imported captures remain available regardless of live support.

Acceptance: redacted real advertisement -> capture facts -> profile/evidence ->
validated TD -> host/Runtime observation. Exercise adapter absence, active-probe
denial, slow consumers, cancellation, owner loss and private-address changes.
Dependency load must not power a radio or begin scanning.

## Phase 5 — direct cellular tracker

Select exact finished device/firmware and operator-controlled endpoint after
WTR.09 qualification: TAT140 is the first target; ATC700 is separately qualified.
Pin authoritative framing, codec/IO, checksum, identity, acknowledgement and
resource/deadline contracts before opening a listener.

Separate bounded framing, session negotiation, pure decoding and authorized
admission. Use OTP sockets or one justified host listener library, not a duplicate
WoT stack. IMEI/CRC is not authentication. Login/heartbeat/command messages need
not contain positions; a data frame may contain multiple records.

Acceptance: independent fixtures and software-peer tests for every split boundary,
coalescing/truncation, counts, unknown fields, ACK outcomes, reconnect, duplicates
and unknown commits; then real direct-to-operator evidence with exact firmware/
network. Telemetry support does not establish a qualified physical Action.

## Phase 6 — deterministic tracking and policy

The pure tracking foundation admits normalized position evidence, versioned
freshness policies with explicit clock qualification and deterministic
multi-source selection. Evidence-bound event ordering implements fixed timestamp
ties, bounded late arrivals and modular sequence wrap/reset/reconnect semantics.
The trusted profile-decoder seam now accepts bounded normalized position claims,
content-identifies them with the observation and catalogue snapshot, constructs
ordinary `Position` values through the complete evidence bundle, and revalidates
stored output without rerunning code. Ruuvi RAWv2 remains explicitly
positionless. The service can now admit an exact trusted catalogue/model/decoder
set, selects its configured callback only after deterministic resolution, and
commits a redacted public position state beside private complete evidence.
Bounded circle/polygon membership is implemented with explicit boundary,
uncertainty and antimeridian rules. See the
[position guide](../guides/positions.md) and
[geofence guide](../guides/geofences.md). Ordered baseline, entry/exit, bounded-gap
and fence/rule-edit recomputation are implemented with stable event identities and
explicit live/replay effects. Sparse crossing inference identifies both endpoints,
enforces time/distance gaps and makes no route or crossing-time claim. The service
re-evaluates complete crossing inputs and atomically deduplicates its stable event
intent without inventing canonical state. Two-fix motion classification implements
bounded distance/speed uncertainty, hysteresis, impossible-speed rejection and
gap handling. Consecutive-segment dwell establishes stationary/moving state and
stable trip start, stop and interruption events without treating one segment as
a trip. Bounded trip-distance reconstruction sums only adjacent segments proved
moving and retains explicit exclusions. Bounded route replay now orders exact
position samples under an explicit clock/quality policy and creates visible
segment breaks after rejected positions or excessive time/distance gaps, without
inferring a missing path. The service reconstructs those samples from private
retained evidence and exposes snapshot-pinned public pages whose pseudonymized
missing/ambiguous exclusions split segments; continuity is explicitly local to
each page. The service atomically persists pending
dwell, active-trip state and stable trip event intent with restart recovery. See
the [motion guide](../guides/motion.md).
Thing-bound trip start, stop and interruption alerts are also available through
a dedicated newest-first, snapshot-pinned page, separate from unrelated rule
alerts. The shared browser presents that exact event timeline, pairs endpoints
only within one displayed page and reauthorizes bounded cursor-free exports; it
does not infer distance from the event page. A separate read-authorized service
operation now reconstructs an immutable completed trip from at most 100 exact
retained position materialisations under the policy committed at trip start. It
publishes bounded distance and explicit segment exclusions without private
evidence identities; incomplete, ambiguous and noncanonical cohorts fail
closed. Its default 30-day half-open UTC window is submitted to the service,
while fixed-offset timezone and exact millisecond/second interval controls
remain presentation choices recorded in the export. Fixed offsets are labelled
as not following daylight-saving changes. Each terminal event now links to a
dedicated shared final-summary screen. It validates and displays exact bounded
metres plus every included/excluded segment, retains valid content across a
temporary read failure and reauthorizes an identity-matched bounded export.
Closed fixed-offset timezone and metre/kilometre/international-mile controls are
presentation-only; conversions declare three-decimal rounding, retain canonical
metres and are recorded in the export.

Receiver-observation heartbeat state is implemented as a pure caller-ticked rule
with exact overdue equality, newer/historical ordering, recovery, revision
recomputation and stable live/replay events. See the
[heartbeat guide](../guides/heartbeat.md). The service atomically persists its
canonical state, history and stable event intent with restart recovery. The
explicit service host now rebuilds bounded monotonic deadlines and commits live
ticks without dispatching physical Actions.

Low-battery state is implemented over content-bound measurement samples with
explicit kind/unit scope, freshness, future skew, suspect-quality policy and
separate low/clear thresholds. It never derives percentage from voltage. See the
[battery guide](../guides/battery.md). The service atomically persists its
canonical state, history and stable event intent with restart recovery. Bounded
freshness/future-skew scheduling is implemented. Principal-isolated APNs endpoint
registration with encrypted token custody and rotation is implemented;
live alerts now atomically stage minimal per-endpoint references. An explicitly
configured supervised dispatcher rechecks current authority and exact endpoint
revision, records distinct provider outcomes and preserves retryable work. The
explicit ES256/HTTP/2 APNs adapter is implemented; provisioned physical delivery
and notification tap routing remain subsequent work.

Suspicious movement is implemented as a pure three-valued conjunction over
confirmed motion and content-bound armed/owner-presence facts. Unknown presence
remains unknown unless the rule explicitly treats it as absence. See the
[suspicious-movement guide](../guides/suspicious-movement.md). Atomic host
deduplication now restores all inputs, re-evaluates the rule and records its event
intent without synthetic state. The service now commits an authorized, retained
`asset.armed` fact for an enrolled Thing and exposes only its reviewed public
state; this administrative operation claims no device contact. The service also
admits a complete exact or strong `owner.present` fact associated with the Thing,
requires its receiver observation time to advance and exposes no private evidence.
Administrators can now save a suspicious-movement definition that privately
binds the exact referenced motion policy for the same Thing, with closed fact-age,
future-skew and unknown-presence treatment. The event-only definition creates no
synthetic rule state. Definition saves, motion materialisations, arming changes
and owner-presence admissions now reevaluate exact live bindings and stage a true
result's intent and alert inside the triggering transaction. Principal-isolated
APNs endpoint registration, encrypted token custody, rotation and removal are
implemented. Live alerts atomically stage minimal per-endpoint references;
the provider-neutral supervised dispatcher and durable outcome handling are
implemented. The explicit ES256/HTTP/2 APNs adapter is implemented; provisioned
physical delivery and notification tap routing remain subsequent work.

Transport degradation is implemented as pure state over content-validated
transport decisions and a deployment-declared healthy candidate set. Fallback
and no-route outcomes are distinct from pending, unknown and stale decisions;
degradation, recovery and rule-edit events have stable identities. See the
[transport policy guide](../guides/transport-policy.md). The service now
atomically persists this rule's canonical state, history and stable event intent
with optimistic prior-state identity and restart recovery. Decision
freshness/future-skew scheduling is now implemented. Input-triggered orchestration
and notification delivery remain for geofence evaluation; suspicious-movement
notification delivery remains open.
Readers can inspect every persisted rule kind's current status and history through
the read-only service `rules` resource without receiving its private evidence.
Administrators can now persist versioned heartbeat, battery, motion, geofence and
suspicious-movement rule definitions for enrolled Things through the service.
The suspicious definition binds one exact same-Thing motion policy privately;
saving it does not manufacture a current status. Saving a stateful definition
and materialising its Thing evaluate it atomically against committed evidence;
position rules fail closed unless the bundle has exactly one position, rather
than inventing source selection. The scheduler ages the time-driven state. Every
rule event becomes a public alert, and administrators can acknowledge a live
alert once. The shared browser can inspect and conditionally change the retained
arming fact for an asset with a motion definition. Closed owner-presence evidence
can be admitted through the service but is not inferred or editable in the shared
browser. Suspicious-movement orchestration is implemented at definition, motion,
arming and presence mutation boundaries. Notification endpoint registration is
implemented and live alerts atomically stage delivery references. Explicit
provider-neutral dispatch, exact authority/revision rechecks and durable provider
outcomes are implemented. The explicit ES256/HTTP/2 APNs adapter is implemented;
provisioned physical delivery and the mobile tap path remain open.

Implement explicit time/freshness, quality selection, motion/trips/stops,
geofence membership/transitions, heartbeat, suspicious movement, low-battery,
late-data handling, deduplication and transport-policy values under WTR.05/06.

Fix remaining rule revisions, thresholds and event idempotency before each state
machine. State transitions are pure; persistence
atomically records state, deduplication and event intent. Baseline needs no Nx/AI.

Acceptance: independent replay/property expectations, jitter and threshold equality,
first membership, sparse inferred crossings, antimeridian/boundary cases, missing
accuracy, valid zero coordinates, counter resets and separate clock domains.
Historical processing must not retrigger live physical Actions. A limited sensor
profile remains valid but cannot satisfy missing smart-bike hardware requirements.

## Phase 7 — optional LoRaWAN integration

Select hardware only after WTR.09 and operator key/network-server control.
Preserve network-server reception/deduplication evidence separately from application
payload decoding. No LoRaWAN server or external decoder runtime enters the core.

Acceptance: exact regional/network/device record and bounded real path. Radio
capability and network ACK do not imply nationwide coverage, application delivery
or physical control. This integration is not a prerequisite for other phases.

## Phase 8 — bootable Pi 5 service and local control panel

Implement WTR.14 in `hosts/nerves/`, beginning with headless firmware and
fixture/software-peer ingress. Boot explicitly starts the accepted service.
Qualify the exact target runtime, board, EEPROM, media, network and update path.
Add BLE only after its controller/backend passes Phase 4.

Complete both product profiles: durable headless service on `nerves_system_rpi5`
and shared LiveView on `kiosk_system_rpi5` with local Cog display. Physical touch
acceptance covers setup, map/history, graph gestures, keyboard/focus/scaling,
offline use and browser failure without ingestion loss.

Execute storage/reboot/power-interruption, full/unmountable filesystem,
firmware-validation and rollback tests on the actual target. Fix and measure
boot/render/memory/power budgets before qualification. A cross-build, HTTP response
or browser on another computer cannot complete local-panel acceptance.

## Phase 9 — optional Refpath showcase

Refpath is private, under development, absent and disabled by default. A separately
configured connector may present a promotional read-only investigation and governed
Action proposals over validated public affordances. Public tests need no private
source or credentials.

Acceptance: a synthetic connector example, disabled/absent and failed-connector
tests, with separately labelled private live execution if available. Version
the connector schema and test authorization/redaction under WTR.11. No synthetic
showcase is labelled real interoperability or general public availability.

## Phase 10 — complete shared LiveView application

The first shared package and optional app-host composition implement sign-in,
bounded asset/observation browsing, one-file Observation JSON import in Setup,
source evidence, confirmed enrollment, later observation association, explicit
Thing provisioning and updates, retained
measurements and paged history. The host
owns the listener, credentials and supervision; the package calls the authorized
service facade. Stable operation URLs recover durable outcomes on reconnect.
Overview, asset-detail and retained state-history surfaces now present every
redacted position claim with its source, uncertainty, quality and qualified
times. Empty position collections and unavailable claims remain explicit; no
screen chooses a canonical source, infers a route or claims live connectivity.
The service boundary for a later history screen is implemented as authorized,
snapshot-pinned route pages with explicit gaps and page-local continuity.
The shared route-history screen now selects that closed policy, plots only the
returned page-local segments and exposes exact points, rejections, exclusions
and break reasons without a basemap or cross-page join. Its bounded page export
reauthorizes and reproduces the displayed identity before emitting cursor-free JSON.
The asset page can also read declared scalar Properties from the committed
service snapshot through current `read` authority. Overview cards fetch each
asset's retained state separately and disclose unprovisioned, unavailable and
prior-source readings without claiming live connectivity. They also distinguish
armed, disarmed, unknown, unavailable and unsupported arming state. Assets with
a motion definition link to a shared arming screen whose administrator controls
use a stable operation, generation check and explicit confirmation; committed
state is reread before success and never described as a device change.
Revocation, read-only denial, stale writes, lost replies and real HTTP session
security are exercised. The UI-enabled bundles also pass an authenticated
browser asset and restart probe. A shared Protection page and per-rule history
now present committed rule status without evidence. Administrators can add,
edit and delete heartbeat, low-battery-voltage, motion/trip and circle or polygon
geofence rules for a provisioned asset in the browser, and review and acknowledge
their alerts. Once a motion definition exists, the browser also creates and
manages an event-only suspicious-movement definition without inventing current
state. Its arming screen presents reviewed owner-presence state read-only and
keeps missing evidence distinct from absence. Position-policy forms preserve ordering, lateness, sequence,
uncertainty, geometry, gap and dwell fields without choosing among position
sources. Each provisioned asset
lists its live rule definitions, stops offering new rules at the service's
eight-definition limit and pages the alerts those definitions recorded.
Administrators can remove an enrolled asset from current views after a stated,
confirmed and recoverable operation; data deletion remains open. An Activity page
pages the credential's recent committed changes for recovery. The shared
package now also provides a bounded HTTPS client whose closed action mapping
uses the same versioned service endpoints, validates exact envelopes and makes
ambiguous mutations recoverable without automatic replay. Complete application,
accessibility, Pi and mobile acceptance remain open.

Implement WTR.15's shared components and `hosts/app/` after Phase 3; use admitted
fixtures before hardware is available. Do not wait for LoRaWAN or private AI.
Use LiveView/HEEx, ordinary forms, bounded streams and narrow browser hooks.

Acceptance: setup, overview, map/history/trips, protection, interactions, privacy,
recovery and evidence inspection through public services. Include revoked access,
bounded streams, unavailable capabilities and Refpath absence. Developer tools
are not the normal end-user flow; canonical state is not in socket assigns.

Finish analytics with Phase 12 and reuse the same overview/history/analytics
implementation on Pi and mobile. Their physical gates complete the cross-surface
claim. Headless consumers remain useful without any web package.

## Phase 11 — native WebView mobile companion

Implement WTR.15 in `hosts/mobile/`: shared LiveView, local Phoenix, bounded cache
and versioned remote service access. Evaluate Mob against required capabilities.
Supply narrow native bridges or choose another compatible shell where necessary;
never delete a requirement to accommodate a framework. Generic BLE work stays
in the existing protocol owner.

The versioned API exposes one current-access projection after read authorization,
including only the current credential's non-secret identity, requested-scope
grants and expiry. Both the in-process and remote HTTPS UI adapters consume that
projection. The remote adapter uses verified TLS, bounded one-shot requests and
stable mutation identity without automatic replay. The independent mobile host
now pins Mob 0.9.1 to Elixir 1.19.5 / OTP 27 without raising the root floor. Its
SQLite cache retains only size-, age- and account-bounded overview, history,
dashboard and map projections, labels age/completeness, securely purges on
authority changes, expiry and sign-out, and exposes no offline mutation or
physical-Action queue. The executable shell now composes the shared router behind
a bounded loopback-only Bandit endpoint and one Mob WebView. A fresh native
capability bootstraps an encrypted/signed HTTP-only session, remains required
through LiveView admission and session renewal, and never enters page assigns.
The exact local origin bounds navigation and WebSocket origin checks; canonical
external HTTPS links leave the bridge-bearing WebView. Mobile remote requests
invoke the Mob OS-resolver seam while preserving the configured HTTPS authority.
An app-owned iOS Mob plugin now provides two closed device-only Keychain slots,
explicitly disables synchronization and has no file fallback. Credential/cache
lifecycle wiring and cache/view synchronization now restore an account-bound,
read-only offline presentation and reconnect it through bounded native lifecycle
events. The pinned notification plugin and an optional supervised registrar now
request permission, register one installation-bound APNs endpoint through the
current authorized session and route an exact opaque notification reference to
the local shared alert screen. No provider token is persisted. Existing bounded,
reauthorized JSON exports now keep browser downloads while an exact closed bridge
routes their content to Mob's native text share sheet. Because the pinned
first-party Bluetooth plugin is peripheral-only, an app-owned CoreBluetooth
plugin now supplies the closed iOS central scan/connect/discover/read/confirmed-
write transport seam without duplicating tracker protocol or WoT mapping.
Signed Xcode/APNs configuration, a qualified target profile and every physical
native/device gate remain subsequent work.

Acceptance: real iPhone secure storage, authorized BLE central provisioning,
notification registration and cold/warm/background tap routing, suspend/resume,
offline inspection, server/account isolation, safe external navigation, bounded
bridge and signed installation. Verify exact plugins/runtime/SDK, not just wrapper
tests. No permanent background BEAM or automatic offline Action replay is assumed.
Phone-as-tracker support has its own source/profile qualification.

Document local Xcode builds and reproducible distribution. Account, signing and
funding prerequisites can block distribution but cannot waive acceptance.
Sponsorship and external build tools are not runtime dependencies. Public upload,
store submission and account operations require separate authorization.

## Phase 12 — interactive analytics and prompted queries

Implement WTR.16 telemetry, bounded local operational history and deterministic
queries over durable tracking data. Add shared live graphs, pan/zoom, filtering,
accessible tables, saved rolling dashboards and fixed incident snapshots.
UI and non-Elixir clients use one closed query/result schema.

The query foundation and first service adapter are present: closed
content-identified rows, absolute UTC query/result values, bounded numeric bucket
aggregation, stable last-observed ties, explicit missing/quality exclusions and
preserved gaps. The service reauthorizes against a pinned SQLite snapshot,
exposes the same closed documents to independent HTTP clients, bounds global and
per-principal work, and cancels timed-out or abandoned scans. The transactional
service now also saves, versions, executes and tombstones owned absolute and
rolling query definitions with closed visualization options; each rolling
execution resolves and returns fresh absolute bounds. A closed telemetry
vocabulary now covers requests, queries, import admission/decoding, transactional
commits, forward-queue depth and overflow, publication reconciliation and store
resource checks. The explicitly supervised bounded ETS collector gives the
default host restart-identified local operational history. Snapshot-pinned
bucket pagination now excludes concurrent commits and reauthorizes every page.
The explicit HTTP host now adds global BEAM memory/process/port samples to that
collector. Host-only operational pages pin its epoch and high-water sequence.
The shared operational view also binds a closed UTC time window to that snapshot,
spaces discrete marks by elapsed time and discloses its 1,000-point projection
limit while retaining exact 25-row pages.
An optional asynchronous exporter drains sanitized samples in bounded batches
through a host adapter. Its acknowledgement checkpoint survives ordinary retries
and explicitly reports retention gaps or collector restart; destination transport,
authorization and any remote query adapter remain host policy.
The shared browser now executes a bounded per-asset structured query and shows
its committed snapshot, bucket values and exclusions in line/area/point graphs
and an accessible table. Gap-separated paths and time-window controls support
historical exploration. A valid/suspect quality selector feeds the same closed
query and persists with a saved definition. The optional browser host records
closed LiveView render durations in the same volatile collector. Reconnect and
OS-native resource events remain. The unsaved per-asset analytics page can opt
into a five-second committed-event check that reruns only after a change, keeps
the selected duration while moving to the newest retained asset state, marks a
temporary failure stale and stops on terminal denial or historical navigation.
General dashboard composition and sharing, a recorded real public-provider
prompt run and the physical UI acceptance gates remain.
The shared browser can also list saved query definitions and rerun one under
current read authority. Administrators can save a displayed graph with a fixed
or rolling window and recover a lost reply by operation reference.
They can also save it as an incident snapshot pinned to its committed generation
and result identity, which later commits do not change. They can
edit its title/view or delete it with the same generation and receipt rules.
An open saved dashboard can follow committed changes: it checks the committed
event cursor every 5 seconds, reruns only after a commit, reruns a rolling
window every 30 seconds, retains a marked stale result through a temporary
failure and clears it if the definition or read authority disappears.
The currently displayed query result can also be exported as its exact closed
JSON document without selecting a new snapshot.
Administrators can select two to eight saved definitions with identical query
settings and window policy and distinct series, then save a new multi-series
exact-table dashboard with a generation check and recoverable operation receipt.
This covers compatible series comparison, not arbitrary dashboard composition.
Saved multi-series queries also support line, area and point views on a shared
value scale, while keeping per-series gaps and tables visible.
A reader can temporarily switch the current saved result between graph and
table views without rerunning it or changing the stored definition.

Add an explicitly configured public model adapter for question-to-query translation:
synthetic boundary tests plus a separately recorded real-provider execution.
The service validates, authorizes and executes queries. Optional BeamLens and
Refpath investigations retain the same policy boundary. Exporters are optional.

Acceptance: known-answer queries, scope isolation, native numeric fidelity,
missing/zero values, units/timezones, snapshot consistency, limits/cancellation,
malicious model output and provider/exporter/collector failures. Test dynamic
graphs and saved-query semantics on every required surface. Tracking and structured
analytics work with AI and remote metrics absent. A screenshot/notebook is not
dynamic-graph acceptance.

## Phase 13 — integrated smart-bike product

Execute WTR.15's same-tracker scenario across web, physical Pi panel, real iPhone
and an independent non-Elixir client with required hardware qualified. Verify
identity, evidence, units, generations and event IDs end to end. Kill/restart
components, disconnect networks, revoke access and replay duplicate ingress while
preserving durable history and preventing repeated physical effects.

Complete every required catalogue delivery target, resource budget, clean artifact
and operator recovery instruction. Signed install, actual distribution and store
acceptance are separate evidence, performed only with appropriate authority.
Missing prerequisites leave the affected gate unpassed. Neither a spec review
nor a successful subset is product completion.

## Dependency adoption and release gates

Before installing an integration, pin its source/release, inspect startup,
configuration and native dependencies, test absence/presence and run the required
runtime matrix in isolated consumers. New releases do not silently change an
accepted cohort. An Nx major version requires separate compatibility work.

Every implemented batch runs targeted tests followed by the complete WTR.13 gate
with no failed-only retry. Public library release additionally requires real BLE
evidence, a finished direct cellular lane, exact cross-repository artifact
compatibility and fixture/log privacy checks. No artifact is published by this plan.

Nerves, UI, mobile and analytics do not block the first pure software milestone,
but MUST pass before complete product acceptance. LoRaWAN/Refpath remain optional
integrations, advertised only after their own gates. Gate scope and evidence
must distinguish core software, library release, host/device and full product.

No push, tag, workflow trigger, publication, visibility change or device flashing
is authorized merely by this plan. Local builds and inspection are distinct from
publishing artifacts or writing a selected physical device.
