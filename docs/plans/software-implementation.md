# Software implementation sequence

This plan orders accepted work by executable dependency. Implementation has started with Phase 0. The current executed scope and unpassed
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
for declared architectures; exercise them with an independent non-Elixir client
in a clean environment without a BEAM toolchain. No external database server,
AI provider, Lab or UI is required for this service gate.

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

Implement explicit time/freshness, quality selection, motion/trips/stops,
geofence membership/transitions, heartbeat, suspicious movement, low-battery,
late-data handling, deduplication and transport-policy values under WTR.05/06.

Fix rule/geometry revisions, units, uncertainty, thresholds, tie ordering and
sequence reset/wrap before implementation. State transitions are pure; persistence
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
