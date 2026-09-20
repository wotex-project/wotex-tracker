# WTR.12 Executable evidence, fixtures and PoC graduation

## Status

This contract defines the independent completion axes inherited by every WTR
contract and also inherits WTR.13's greenfield Zig policy. Missing external
prerequisites never block locally executable implementation.

Implemented for the repository's software evidence classes: unit/property tests,
source-derived and synthetic fixtures, independent protocol peers, real local
socket/HTTP/SSE integration, Runtime/HTTP-binding interoperability, clean archive
consumers and bounded release/image lifecycle probes are recorded without class
promotion. The required real TAT140, Pi 5, iPhone and integrated
field/product gates remain unpassed, so no hardware-qualified or complete-product
claim is made. See the [implementation evidence](../evidence/implementation.md)
and [fixture provenance](../provenance/ruuvi-raw-v2-fixtures.md).

## Evidence classes

Tracker distinguishes:

- `unit` — pure matching/decoder/materialisation/rule tests;
- `fixture` — captured protocol bytes/advertisements with provenance;
- `simulator` — deterministic protocol peer/device simulator;
- `integration` — real scanner/socket/broker/network-server integration;
- `hardware` — real qualified physical device;
- `interoperability` — interaction through WoTEx bindings/runtime/directory; and
- `field` — bounded real deployment evidence such as Sweden/EU868/cellular operator testing.

No README claim may promote a lower evidence class as if it were higher.

## Independent completion axes

Every contract and delivery target uses these axes independently:

1. `development_status` covers repository-owned code, local build tooling,
   packaging, failure handling and automated tests. Its allowed states are
   `not-started`, `in-progress` and `complete`; `blocked` is deliberately not an
   allowed state. If a behavior can be implemented against a bounded local
   substitute, absent hardware, credentials or accounts do not excuse leaving it
   unwritten.
2. `local_acceptance_status` covers executable fixtures, deterministic protocol
   peers, simulators, emulators, QEMU, containers and loopback integration. Its
   allowed states are `not-started`, `in-progress` and `passed`.
3. `qualification_status` covers real TAT140/radio/carrier operation, physical
   Pi/iPhone behavior and real public-provider exchanges. Its allowed states are
   `not-required`, `not-started`, `in-progress` and `passed`.
4. `distribution_status` covers package/store accounts, registry configuration,
   signing authority, uploads and external review. It uses the same external
   states as qualification.

Development MUST reach `complete` before local acceptance can pass. Qualification
and distribution may remain `not-started` while their external prerequisites are
unavailable, but that state never propagates backward into development. Local
tests exercise success, denial, timeout, malformed input, disconnect, retry and
recovery for every external seam. A real external run then verifies the same
contract without replacing those tests.

For Apple work, the iOS simulator, local native peers and fake APNs provider are
development/local-acceptance evidence. A physical iPhone, real BLE interaction,
APNs entitlement and provider delivery are qualification evidence. Developer
Program enrollment, App ID/certificate/profile registration, upload and review
are distribution evidence. These three claims MUST remain distinct.

## Fixture provenance

Every non-synthetic capture fixture MUST record device model, protocol/firmware revision when available, capture method, redaction/transformation, expected decoder/profile revision and source/license/permission. Credentials and stable personal identifiers are removed or deterministically replaced.

Published documentation vectors are source-derived fixtures, not real captures made by this project. Synthetic vectors record generation rules and independent expected values. Redaction must preserve framing/checksums where applicable and document any recomputation; the redacted digest is not the original capture digest. Commit neither a reusable secret nor a real stable identifier merely because it appears in a vendor example.

## Software milestone evidence

The first software milestone is imported evidence -> resolution -> pure reference-fixture decode -> capabilities -> self-contained model -> upstream-validated TD. The existing Ruuvi RAWv2 vector is only one deterministic parser fixture. It requires no process, live radio, Runtime, Directory, Lab, Nx, AI or database and proves no real endpoint is reachable. The first complete hardware PoC below is a later, stronger milestone and requires the explicit host/runtime lane.

For each executed claim record the test command, full suite/selection, exit status, runtime/OS/architecture, Tracker revision or artifact digest, exact dependency identities, fixture/model/profile revisions and observed result. Catalogue `target_evidence`, `current_evidence`, `implementation_status` and `evidence_refs` are distinct. Empty evidence references never imply acceptance. Documentation/reference integrity checks validate specifications, not Tracker behavior.

## Required tracker qualification PoC

The baseline physical acceptance path is:

```text
real Teltonika TAT140, exact EU variant and firmware
 -> operator-owned SIM and direct LTE Cat 1 endpoint
 -> bounded IMEI negotiation and Codec 8 Extended acknowledgement
 -> deterministic TAT140 profile resolution
 -> normalized GNSS position, movement and supported battery evidence
 -> materialise a validated TD from the tracking Thing Model
 -> expose/consume through WoTEx Runtime
 -> observe value through headless API/CLI
```

No AI and no vendor cloud may be required.

## TAT140 BLE-sensor path

The same qualified TAT140 also exercises its documented short-range radio before
using the long-range path:

```text
selected physical BLE sensor
 -> TAT140 BLE scan under an exact configured mode
 -> documented AVL sensor IO in a real device record
 -> direct LTE delivery to the operator-controlled listener
 -> preserved BLE provenance and normalized supported measurement
 -> the same validated tracking Thing and WoT interface
```

This proves the selected tracker can bridge a documented local sensor radio to
the long-range path. It does not prove an iPhone provisioning protocol; that
separate WTR.15 interaction must be verified against its exact interface.

## Optional LoRaWAN path

A LoRaWAN hardware profile graduates only after direct control of LoRaWAN credentials/network-server integration and real EU868 hardware evidence. It should demonstrate transport policy/fallback but is not required for baseline Tracker viability.

## Negative tests

The suite MUST include malformed/truncated/oversized payloads, unknown versions, ambiguous fingerprints, BLE random-address changes, replay/duplicate records, impossible measurements/positions, stale timestamps, credential leakage checks, unauthorized active probes, unauthorized physical Actions and vendor-cloud-only profile rejection.

First-slice tests additionally cover native JSON type preservation, duplicate keys and aliases, malformed options, unavailable versus false/zero, bounded nested input, duplicate identities, dangling/cyclic lineage, conflicting profile revisions, catalogue permutations, model subset rejection and missing deployment Forms. Later tests include sequence reset/wrap, multiple receivers, unknown commit outcomes, stale publication generations and crash recovery under WTR.05/06/13. Hardware-only cases cannot silently pass as skipped when their lane is explicitly selected.

## Package and integration evidence

Apply the full gate in WTR.13, including actual archive contents and clean consumers. Path builds prove only the recorded source cohort. Verify core-only consumers with all optional integrations absent, then each admitted integration with compatible packages present. At minimum the host lane must show the same admitted fixture/TD being used through Runtime and the selected binding with a real local software peer; a mock transport alone does not prove HTTP/MQTT interoperability.

Optional `wotex_conformance` reports use its external artifact boundary and exact corpus/subject identity. They cannot be relabelled Tracker hardware qualification. Lab may help experiment but owns no Tracker acceptance gate. Refpath-private execution is separately labelled and never required for public software acceptance.

## Product acceptance

The required delivery targets in `catalogue.yaml` bind the complete product to
owning contracts and explicit evidence. Core-only software and library-release
gates remain separately scoped. The product MUST additionally pass:

1. durable standalone service, versioned HTTP/OpenAPI/SSE and clean non-Elixir
   release/image consumption under WTR.06/07;
2. the qualified TAT140 direct-cellular and BLE-sensor paths plus smart-bike
   capability coverage under WTR.09;
3. the complete shared application workflows under WTR.15;
4. physical Pi 5 headless boot/recovery and local touch-panel operation under WTR.14;
5. real iPhone native bridges, lifecycle, secure storage, signed installation and
   the documented distribution path under WTR.15;
6. known-answer analytics, actual dynamic graphs, saved-query semantics and a real
   public-provider prompted query under WTR.16; and
7. the integrated same-tracker web/Pi/iPhone/non-Elixir scenario under WTR.15.

Delivery prerequisites refer to completed acceptance, not module build order.
Each target accepts its listed behavior, not every downstream feature mentioned
by an owning contract. The headless-service target proves admission, durability,
machine-interface foundations and clean artifacts; feature targets extend and
test that same API. Complete service capability is checked again in the integrated
product, so foundation acceptance cannot advertise unimplemented operations.
The analytics target verifies query/provider contracts and browser graph behavior;
the shared-application target verifies complete browser workflows using them.
Pi/mobile targets verify their physical surfaces, and the integrated target binds
the same tracker across all of them. Shared UI modules can be developed before
any complete application target passes. Cross-surface requirements are discharged
in the physical/integrated targets, without circular prerequisite waivers.

An explicitly selected gate fails when its required test is skipped or its
prerequisite is absent. No upstream demo, synthetic peer, build, static screenshot,
funding plan or documentation check can substitute for the corresponding real
execution. Funding/account/store-review status is recorded separately from
software/hardware results, with remaining distribution prerequisites unpassed.
Private Refpath and optional LoRaWAN do not replace or gate public product paths.

The evidence record must identify which shipped artifacts and configuration
profiles passed, including UI-disabled and integration-absent operation. Resource
budgets are fixed for the selected target before qualification. A regression
introduced by a shared module invalidates affected downstream acceptance until
the appropriate scenario is rerun; a passing core test alone cannot restore it.

## Conformance language

Passing Tracker tests does not by itself establish W3C WoT conformance, Bluetooth qualification, LoRaWAN certification, cellular certification, regulatory approval or hardware safety certification. Such claims require their own evidence.

## Graduation

A profile graduates from `research` -> `fixture` -> `integration` -> `hardware-qualified` only when the catalogue's declared gates have executed evidence. Code merged without hardware evidence remains below `hardware-qualified`.
