# WTR.10 WoTEx ecosystem integration

## Status

Accepted target contract. No implementation claim.

## Dependency direction

Tracker is downstream of WoTEx foundation packages. Foundation packages MUST NOT depend on Tracker.

## Cross-repository ownership audit

The Tracker boundary is intentionally aligned with the current repository contracts:

| Concern | Owner | Tracker role |
|---|---|---|
| TD/TM/DataSchema/Form values and validation | `wotex` | consume; never fork |
| Form selection, ConsumedThing/ExposedThing planning, credentials/transport ports, subscriptions, retry classification | `wotex_runtime` | invoke after TD validation; never replace |
| Thing Description Directory registration/retrieval/replacement/listing/expiry/patch/introduction/lifecycle event values | `wotex_directory` | publish/query validated TDs through consumer integration |
| HTTP/MQTT/etc. WoT binding semantics | binding repositories | install/use bindings; do not reimplement in Tracker |
| Host-neutral observation proposals, action intent/result, evidence and delivery/lifecycle exchange values | `wotex_continuum` | optionally project Tracker state across edge/cloud boundaries |
| Canonical physical observations, device/profile evidence, tracking identity association, tracking state and safety policy | `wotex_tracker` consumer/domain | own as the tracking vertical |
| Numerical fusion primitives | `wotex_nx` | optional dependency where deterministic numerical work is needed |
| Experimental cross-repo/hardware qualification | `wotex_lab` | research before graduation into normative Tracker profiles |
| AI/agent/tool orchestration | Refpath | optional downstream consumer/integration |

The critical distinction is that Runtime and Continuum explicitly leave canonical observations, final authority, authorization/policy, persistence and Action-effect truth with the consumer. Tracker is that consumer/domain for tracking-specific evidence and state; it does not move those responsibilities into generic WoTEx core.

## `wotex`

Tracker uses `wotex` for Thing Description, Thing Model, DataSchema, Form, security declaration and validation semantics. Tracker-specific structs MUST NOT become alternate TD/TM implementations.

Thing materialisation ends by constructing a candidate map/value and validating it through `wotex`; a Tracker profile cannot declare a TD valid on its own authority.

## `wotex_runtime`

Once a validated TD exists, Tracker uses Runtime ConsumedThing/ExposedThing mechanics for portable interaction planning. Tracker supplies consumer-owned transports, credentials, supervision and application state according to Runtime contracts.

Runtime does not establish canonical Property truth, authorize an interaction, persist observations, or prove a physical Action effect. Tracker/its host may own those tracking-domain concerns while delegating portable interaction mechanics to Runtime.

Long-lived observations/events remain caller-supervised. Tracker may provide host supervision helpers but must not alter Runtime lifecycle semantics.

## bindings

HTTP and MQTT forms use their dedicated WoTEx bindings when compatible. Tracker-specific cellular/AVL/advertisement decoding happens before WoT exposure and is not mislabeled as an HTTP/MQTT binding.

A generic BLE binding/discovery package is a likely future repository once the PoC proves reusable semantics. Candidate name: `wotex-binding-ble`. It should be created only when a protocol-neutral contract can be stated independently of tracking.

A LoRaWAN repository should likewise be created only if there is a reusable WoT binding/network-server abstraction beyond tracker-specific payload profiles. LoRaWAN radio/network semantics must not be forced into core merely to satisfy this PoC.

## `wotex_directory`

Tracker may publish validated, authorized instance TDs and query TDs through Directory contracts. Unresolved discovery evidence, physical observations, candidate identities, profile matches and hardware enrollment are not Directory content.

Tracker MUST NOT implement its own generic Directory repository semantics, pagination, expiry, Merge Patch, Introduction endpoint semantics or lifecycle event definitions.

## `wotex_continuum`

Continuum is the preferred future boundary for carrying normalized observation proposals, evidence, Action intents/results and deployment-mode values across edge/cloud placement when its contracts fit.

Tracker remains the authority that decides whether continuum-carried input becomes canonical tracking evidence/state. It MUST NOT treat receipt of a Continuum value as proof of device identity, measurement truth, authorization or Action effect.

Tracker must not build a competing generic edge/cloud replication/wire substrate.

## WoT Discovery versus physical discovery

W3C WoT Discovery and `wotex_directory` discovery concern finding Things/Thing Descriptions. Tracker physical discovery concerns observing an as-yet-untrusted physical device before a Thing may exist.

Therefore BLE advertisements, cellular first-contact frames, LoRaWAN uplinks and similar physical observations belong to Tracker/profile discovery. Once a validated TD is published, ordinary WoT Directory discovery owns finding that Thing. These are separate layers and MUST NOT share one ambiguous `discover/1` contract.

## `wotex_nx`

Numerical positioning, anomaly detection or sensor fusion may use NX when deterministic and evidence-preserving. NX is optional; baseline tracking remains functional without it.

## `wotex_lab`

Lab remains the place for experimental hardware captures, cross-repository qualification and exploratory protocol work that is not yet an accepted Tracker contract. Once a profile is accepted, its normative contract/fixtures graduate into Tracker.

## Possible new repositories

The PoC is expected to reveal reusable packages. The current recommended candidates are:

- `wotex-binding-ble` — generic BLE Form mapping plus explicitly bounded discovery primitives, if the contract proves useful beyond tracking;
- a LoRaWAN integration package only if generic network-server/application semantics emerge; and
- no dedicated Teltonika repository initially: AVL tracker decoding is a vertical profile/adapter until broader non-tracking reuse is proven.

Repository creation is a graduation decision, not a prerequisite for the PoC.
