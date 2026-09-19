# WTR.10 WoTEx ecosystem integration

## Status

Accepted target contract. No implementation claim.

## Dependency direction

Tracker is downstream of WoTEx foundation packages. Foundation packages MUST NOT depend on Tracker.

The required product hosts and shared packages in WTR.15 remain downstream
consumers. Service -> Tracker -> WoTEx values is the dependency direction; UI
and mobile/Nerves platform integration never enter root library compilation.
Runtime and analytics conveniences cannot introduce application policy upstream.

## Cross-repository ownership audit

The Tracker boundary follows the repository contracts at the [recorded source cohort](../provenance/primary-sources.md). Source availability does not establish release availability or integration acceptance.

| Concern | Owner | Tracker role |
|---|---|---|
| TD/TM/DataSchema/Form values and validation | `wotex` | consume; never fork |
| Form selection, ConsumedThing/ExposedThing planning, credentials/transport ports, subscriptions, retry classification | `wotex_runtime` | invoke after TD validation; never replace |
| Thing Description Directory registration/retrieval/replacement/listing/expiry/patch/introduction/lifecycle event values | `wotex_directory` | publish/query validated TDs through consumer integration |
| HTTP/MQTT WoT binding semantics | `wotex_binding_http`, `wotex_binding_mqtt` | supply client ports in a host; neither package is a server or broker |
| BLE/GATT values, operations and Form mapping | `wotex_ble` | consume public APIs; separately qualify passive scanning |
| CoAP, Thread, BACnet, Matter, Modbus and OPC UA | `wotex_coap`, `wotex_thread`, `wotex_bacnet`, `wotex_matter`, `wotex_modbus`, `wotex_opcua` | optional protocol integrations only for evidenced profile needs |
| Host-neutral observation proposals, action intent/result, evidence and delivery/lifecycle exchange values | `wotex_continuum` | optionally project Tracker state across edge/cloud boundaries |
| Canonical physical observations, device/profile evidence, tracking identity association, tracking state and safety policy | `wotex_tracker` consumer/domain | own as the tracking vertical |
| Typed observations to tensors/masks and inert numerical outputs | `wotex_nx` | optional numerical conversion; consumer owns model/fusion policy |
| Artifact/vector conformance reports | `wotex_conformance` | optional external verification; no production dependency in either direction |
| Experimental consumer workbench | `wotex_lab` | optional place to experiment; no Tracker dependency or acceptance authority |
| AI/agent/tool orchestration | Refpath | optional downstream consumer/integration |

The critical distinction is that Runtime and Continuum explicitly leave canonical observations, final authority, authorization/policy, persistence and Action-effect truth with the consumer. Tracker is that consumer/domain for tracking-specific evidence and state; it does not move those responsibilities into generic WoTEx core.

## `wotex`

Tracker uses `wotex` for Thing Description, Thing Model, DataSchema, Form, security declaration and validation semantics. Tracker-specific structs MUST NOT become alternate TD/TM implementations.

`Wotex.ThingModel.from_map/2` and `parse/2` validate models; they do not instantiate TDs. Tracker owns only its explicit profile/model selection and bounded transformation under WTR.04. The candidate map enters `Wotex.ThingDescription.from_map/2` with validation enabled. No encode-then-parse round trip is needed for an admitted native map.

## `wotex_runtime`

Once a validated TD exists, Tracker uses Runtime ConsumedThing/ExposedThing mechanics for portable interaction planning. Tracker supplies consumer-owned transports, credentials, supervision and application state according to Runtime contracts.

Runtime does not establish canonical Property truth, authorize an interaction, persist observations, or prove a physical Action effect. Tracker/its host may own those tracking-domain concerns while delegating portable interaction mechanics to Runtime.

Long-lived observations/events remain caller-supervised. Tracker may provide host supervision helpers but must not alter Runtime lifecycle semantics.

## bindings

HTTP and MQTT forms use their dedicated WoTEx bindings when compatible. Tracker-specific cellular/AVL/advertisement decoding happens before WoT exposure and is not mislabeled as an HTTP/MQTT binding.

`wotex_ble` already supplies `Wotex.BLE`, `profile/1`, session-based GATT discovery and Runtime adapters. Its recorded checkout distinguishes existing Python/dbus-next execution from an accepted C++ Port target. Tracker MUST NOT claim that target is implemented, require the legacy backend for its pure core, or reproduce it locally. Passive advertisements, Linux scanning and macOS scanning each require their own public API and evidence. BLE GATT discovery and physical advertisement discovery remain distinct.

A LoRaWAN repository should likewise be created only if there is a reusable WoT binding/network-server abstraction beyond tracker-specific payload profiles. LoRaWAN radio/network semantics must not be forced into core merely to satisfy this PoC.

## `wotex_directory`

Tracker may publish validated, authorized instance TDs and query TDs through Directory contracts. Unresolved discovery evidence, physical observations, candidate identities, profile matches and hardware enrollment are not Directory content.

Tracker MUST NOT implement its own generic Directory repository semantics, pagination, expiry, Merge Patch, Introduction endpoint semantics or lifecycle event definitions.

## `wotex_continuum`

Continuum's `WotexContinuum.*` values and `WotexContinuum.Codec` are an optional boundary for observation proposals, evidence, Action intents/results and deployment-mode values when their contracts fit. The package supplies no transport, replication engine or store-and-forward service; those are host-owned.

Tracker remains the authority that decides whether continuum-carried input becomes canonical tracking evidence/state. It MUST NOT treat receipt of a Continuum value as proof of device identity, measurement truth, authorization or Action effect.

Tracker must not build a competing generic edge/cloud replication/wire substrate.

## WoT Discovery versus physical discovery

W3C WoT Discovery and `wotex_directory` discovery concern finding Things/Thing Descriptions. Tracker physical discovery concerns observing an as-yet-untrusted physical device before a Thing may exist.

Therefore BLE advertisements, cellular first-contact frames, LoRaWAN uplinks and similar physical observations belong to Tracker/profile discovery. Once a validated TD is published, ordinary WoT Directory discovery owns finding that Thing. These are separate layers and MUST NOT share one ambiguous `discover/1` contract.

## `wotex_nx`

`Wotex.Nx.Encoder`/`Decoder` convert explicitly typed observations and numerical outputs. They do not supply a positioning/fusion algorithm or choose, train or serve a model. Any Tracker integration supplies units, time windows, missing-value policy, algorithm and backend evidence. Nx is optional; baseline tracking remains functional without it.

## `wotex_conformance`

Conformance owns corpus/vector identity, an external target protocol and evidence reports. Tracker may be an artifact-under-test through a host-supplied external adapter. Do not make Conformance compile-depend on Tracker, send expected answers to the target, or treat a generic WoT vector as hardware evidence. Reports bind exact artifact/corpus/environment identities and apply only to the exercised claim.

## `wotex_lab`

Lab MAY consume Tracker for experiments if useful. Tracker's implementation, fixtures, package tests, integration tests and hardware qualification MUST stand alone with Lab absent. Lab is neither a prerequisite nor the owner of Tracker acceptance. An experiment may contribute redacted, licensed evidence, but Tracker independently verifies any adopted contract. Tracker MUST NOT import Lab modules, hosts, stores, dependency graphs or release assumptions.

The same application independence applies to other sibling products: shared
presentation/query behavior belongs in Tracker's public contracts or a proven
inert shared library, never a dependency on another product's application tree.

## Possible new repositories

No new repository is required by the first milestone. Review reuse only when a concrete capability demonstrates it:

- extend the existing `wotex_ble` owner for reusable BLE capabilities;
- a LoRaWAN integration package only if generic network-server/application semantics emerge; and
- no dedicated Teltonika repository initially: AVL tracker decoding is a vertical profile/adapter until broader non-tracking reuse is proven.

Repository creation is a graduation decision, not a prerequisite for the PoC.

## Dependency installation boundary

The pure milestone requires only `wotex` as a WoTEx dependency. Runtime and bindings enter when an executable interaction lane needs them; Directory, Continuum, Nx and Refpath remain optional host/adapter integrations. Prefer isolated host Mix projects for concrete clients, web servers, stores and native backends. Do not reference absent optional structs at core compile time or infer an adapter from installed modules.

Coordinated development uses the existing `WOTEX_PATH_DEPS=1` convention only in
dev/test/docs with explicit declared paths below the sibling WoTEx monorepo's
`packages/` directory. Reject other values and production use. Ordinary package
requirements use compatible available releases; immutable local archives may
prove a source cohort separately. A sibling directory, `0.1.0` package metadata
or path build is not proof of a published compatible release.

## Product dependencies and services

Required behavior does not make every integration a mandatory root dependency.
The implementation must record exact compatible versions and executable evidence
for each selected host cohort; a candidate name is not an installed dependency.

| Concern | Planned implementation boundary | External service requirement |
|---|---|---|
| HTTP/JSON and SSE | Shared service with Plug/Bandit and a pinned OpenAPI contract | None; operator configures bind/TLS/network |
| Durable local data | SQLite driver in the service host under WTR.06 | No database server; alternative databases are deployment adapters |
| Web UI and charts | Phoenix LiveView/HEEx in the shared UI; narrow browser hooks | No frontend SaaS or notebook |
| Pi firmware/display | Nerves, networking/time libraries, Pi system and Cog kiosk profile | NervesHub/cloud management optional |
| Mobile shell | Local Phoenix/WebView; Mob candidate plus required native bridges | OS signing/distribution and configured push provider for that lane |
| Operational metrics | Explicit `:telemetry` contract and bounded host collector | No metrics server; PromEx/Prometheus/GreptimeDB exporters optional |
| Prompted analytics | Closed query engine plus one configured public model adapter; ReqLLM candidate | Selected local or remote model only when prompting is enabled |
| Investigation | Optional BeamLens integration through authorized tools | Configured provider; privileged runtime tools isolated from end users |
| Private AI | Refpath connector under WTR.11 | Private prerequisites only for explicitly enabled Refpath operation |
| Maps | Shared map view with explicit tile/style configuration and bounded permitted cache | Operator-controlled/local sources supported; no mandatory paid map API |
| Numerical processing | Optional `wotex_nx` conversion and qualified algorithm/backend | No required model-serving cloud |

A native renderer or model framework can be replaced at its host boundary only
after the replacement passes the same application/resource/security gates.
Framework limitations do not reduce the product contract. No automatic selection
based on installed modules or ambient configuration is allowed in shared libraries.
