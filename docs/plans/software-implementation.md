# Software implementation sequence

This plan orders accepted work by executable dependency. Tracker currently has
specifications only: no Mix project, runtime code, fixture suite, host or firmware
exists. Every milestone below is **not started**. Specification checks are not
implementation evidence. [WTR.13](../specs/WTR.13-elixir-otp-and-verification.md)
applies from the first line of code.

## Dependency and repository layout

Use a normal root Mix library with `lib/wotex/tracker/`, `test/`, packaged
`priv/thing_models/` and versioned fixture provenance. Only `wotex` is required
by the first pure milestone. Do not create placeholder modules for future work.

Independent host Mix projects own application callbacks, configuration, storage,
network clients and supervision. The planned reference server/UI lives under
`hosts/workbench/`; bootable Pi 5 firmware under `hosts/nerves/`. Both consume
the root library's public API. Share inert UI modules only when both hosts need
them; never start one host application's supervision tree inside the other.
The optional web UI uses Phoenix LiveView/HEEx. It is not a core dependency.

No Tracker dependency on Lab, Refpath, a private source repository or an
unreleased optional protocol package is needed for the pure path. The
[ecosystem contract](../specs/WTR.10-wotex-integration.md) records existing owners.
The source cohort is pinned in [provenance](../provenance/primary-sources.md).
The dated [ecosystem research](../provenance/ecosystem-research.md) records
dependency candidates; recommendations do not install dependencies or accept a
hardware lane.

## Phase 0 — package and verification foundation

Create the Mix library, formatter, test helper, LICENSE/NOTICE, contribution and
security guidance and explicit package file list.
Declare the planned Elixir floor and runtime lanes from WTR.13. Do not manually
write generated release history. GitHub workflows/action pins/topology and
release automation require separate authority and are not changed by this plan.

Implement catalogue validation, local documentation/spec-link checks and an
explicit complete local gate. Catalogue checks reject duplicate IDs/keys, missing
files, unresolved contract references, invalid statuses and evidence promotion
without evidence records. They must distinguish contract-reference edges from
build ordering and optional dependency installation.

Acceptance: clean package compile with warnings as errors, full configured gate,
documentation build and inspected archive; an isolated consumer starts no Tracker
process and imports no optional host/runtime code. A fixture pipeline is not yet
claimed. Missing available upstream releases are reported, not worked around by
changing their constraints. Development paths use `WOTEX_PATH_DEPS=1` only under
the restrictions in WTR.10.

## Phase 1 — observation, resolution and Ruuvi decoder

Implement admitted Observation/Evidence/Profile/Capability/Resolution/Error
values, immutable catalogue input, deterministic declarative matching and explicit
identity association. Then implement the pure RAWv2 decoder before materialisation.

Acceptance: exact/unknown/ambiguous/candidate-only inputs; catalogue permutations
and conflicts; complete lineage and identity collision cases; malformed/oversized
JSON and bytes; unavailable/mixed/zero values; source-derived ordinary and extreme
Ruuvi vectors. A false/zero value survives serialization with its native type.
Changing a single identity-relevant field must break identity equality. No process,
clock read, hardware, persistence or callback-selected wire module is involved.

Pin source snapshots, profile/decoder versions and units with fixture expectations.
Do not describe documentation vectors as real-device captures. Preserve raw
evidence and quality without inventing movement state or battery percentage.

## Phase 2 — self-contained model and materialisation

Implement one environmental-sensor TM and its explicit capability mapping under
WTR.04. Use upstream model/TD constructors and JSON admission. Pass explicit
pseudonymous identity, security and deployment Forms. No model network resolver,
general inheritance engine or templating language is included.

Acceptance: imported fixture -> admitted observation -> profile resolution ->
decoder evidence -> capabilities -> TM selection -> validated TD, with fixed
canonical output and no Tracker-created processes. Test all WTR.04 failure cases
and retained provenance. No unsupported affordance appears; missing mandatory
capability/Form/security fails explicitly.

**This completes only the first pure software milestone.** A synthetic endpoint
declaration does not prove a reachable WoT endpoint. This milestone excludes live
scanning, Runtime integration, Directory publication, databases, CLI/server/UI,
cellular listeners, Nerves firmware, LoRaWAN and AI.

## Phase 3 — explicit headless host and Runtime proof

Add a caller-started reference host and CLI using imported observations first.
Introduce only the discovery/state/clock ports needed by this real host. Use
per-instance volatile state initially and label its lack of durability. Consume
Runtime ExposedThing/ConsumedThing APIs; provide host-owned handlers, credentials,
transport and an actual client through the HTTP or MQTT binding. An HTTP binding
does not supply the server; an MQTT binding does not supply the broker/client.

Acceptance: the same pure fixture-generated TD drives a real local software-peer
Property read and an observation only if the selected binding/host implements it.
Test two independent hosts, authorization, unavailable measurements, unsupported
Forms and teardown. CLI calls use the public API and expose no scanner internals.
Directory registration is a separate authorized integration using its existing
repository contract; it is not required to prove the first Property read.

Before a durable store is added, fix its exact schema/transaction, commit outcome,
retention and crash contract and execute WTR.06 failure injection. SQLite is a
candidate host adapter, not a required dependency or a promise of durability.

## Phase 4 — passive BLE hardware proof

Fix the public scanning adapter and WTR.13 lifecycle budgets before implementation.
The existing `wotex_ble` owns generic BLE/GATT. Its GATT discovery is not a passive
scanner; its accepted native backend target is not assumed finished. Keep missing
upstream work explicit and reuse it only after its own acceptance.

Qualify one OS/controller/backend lane at a time. Linux, macOS and Nerves/Pi 5
are separate claims. Imported captures remain available regardless of live support.

Acceptance: redacted real advertisement -> original capture facts -> deterministic
profile/evidence -> validated TD -> host/Runtime observation. Exercise adapter
absence, active-probe denial, slow consumers, cancellation, adapter/owner loss and
private-address changes. No dependency load powers a radio or begins a scan.

## Phase 5 — direct cellular tracker

Select the exact finished device/firmware and operator-controlled endpoint after
WTR.09 qualification (TAT140 first research target; ATC700 a separate second
target). Specify TCP/UDP framing, record admission, checksum, device association,
acknowledgement count/meaning, maximum frame/record/session counts and idle/deadline
budgets before opening a listener.

Separate bounded framing from pure codec decoding and host admission. Prefer
OTP socket primitives or one narrowly justified listener library in the host.
Do not implement another WoT transport stack or treat IMEI/CRC as authentication.

Acceptance: independent software-peer fragmentation/coalescing/truncation and
record-count/ack tests, duplicates and unknown commit outcomes, then real direct
tracker evidence with the exact firmware/network. No live-control capability is
inferred from telemetry support.

## Phase 6 — deterministic tracking and policy

Implement only the rules supported by qualified measurements: explicit time,
freshness, position-source/quality selection, movement/geofence/heartbeat state,
late data, bounded deduplication and transport-policy values. Fix rule versions,
coordinate/uncertainty semantics and tie behavior before adding each rule.

Acceptance: replay/property tests plus state/commit failure cases under WTR.05/06.
Historical data cannot accidentally retrigger a live Action. Numerical output is
inert and evidence-backed; baseline policy needs no Nx or Refpath.

## Phase 7 — optional LoRaWAN integration

Select hardware only after WTR.09 and operator key/network-server control.
Preserve network-server reception and deduplication evidence separately from
application payload decoding. ChirpStack patterns may inform the adapter; no
LoRaWAN server or JavaScript payload-decoder runtime enters the pure core.

Acceptance: exact regional/network/device record and bounded real path. Do not
infer nationwide coverage, device control, or application delivery from radio
capability or network acknowledgement.

## Phase 8 — optional bootable Pi 5 host

Implement the separate Nerves application under
[WTR.14](../specs/WTR.14-nerves-and-liveview-hosts.md), beginning with headless
firmware and fixture/software-peer ingress. Its host application explicitly
starts the already accepted Tracker service; booting firmware is not starting
Tracker through a library application callback.

Acceptance: pinned reproducible firmware build, physical boot, reboot/recovery,
firmware validation/rollback, storage behavior and optional-UI absence. Add BLE
only after the exact Pi/controller/backend passes Phase 4 qualification. A Pi 5
boot does not prove onboard Bluetooth support. Build/run the same core fixtures
on the target; record target OTP separately from desktop test lanes.

## Phase 9 — optional Refpath showcase

Refpath is private and under development. It is disabled and absent by default.
After validated affordances exist, a separately configured connector may present
a promotional read-only investigation workflow, then governed Action proposals.
Use only the public Tracker/WoT boundary; never make private source necessary to
compile/run public tests.

Acceptance: a public synthetic connector contract example, disabled/absent and
failed-connector tests, and separately labelled private live execution when
available. A synthetic showcase is illustrative; no fabricated private integration
success or public availability claim. WTR.11 controls authority and redaction.

## Phase 10 — optional LiveView workbench

Build a replaceable Phoenix LiveView/HEEx host over the same headless API after
Phase 3. This UI need not wait for cellular, LoRaWAN, Refpath or Pi firmware.
Use server-rendered components, ordinary forms, bounded streams and limited
JavaScript hooks only where browser functionality requires them.

Acceptance: evidence/resolution/TD/state inspection and authorized interactions
through public services; mount/event authorization and access revocation; bounded
history/stream behavior; no canonical state in socket assigns; operation with
Refpath absent. Headless firmware remains useful with all web components absent.
A Pi-hosted web UI is viewed in another browser; local kiosk rendering is a
separate feature, not implied by HDMI or a running web endpoint.

## Dependency adoption and release gates

Use the dated research recommendations only after an adapter demonstrates need.
Pin a candidate release/source, inspect startup/configuration/native dependencies,
test absence and presence, then run the unchanged supported runtime matrix in
isolated consumers. New upstream releases never silently change an accepted
cohort. In particular, an Nx major release requires separate compatibility work.

Every implemented batch runs targeted tests then the complete WTR.13 local gate
with no failed-only retry. A package release additionally requires real BLE
evidence, at least one finished cellular direct-to-operator lane, exact
cross-repository artifact compatibility, fixture/log privacy checks and honest
evidence labels. Optional Nerves/UI/LoRaWAN/Refpath lanes do not block core
software acceptance, nor are they advertised as supported before their own gates.

No push, tag, workflow trigger, release, publication, repository visibility
change or device flashing is authorized merely by this plan. Local firmware
builds and read-only inspections are distinct from writing a selected device.
