# WTR.10 WoTEx ecosystem integration

## Status

Accepted target contract. No implementation claim.

## Dependency direction

Tracker is downstream of WoTEx foundation packages. Foundation packages MUST NOT depend on Tracker.

## `wotex`

Tracker uses `wotex` for Thing Description, Thing Model, DataSchema, Form, security declaration and validation semantics. Tracker-specific structs MUST NOT become alternate TD/TM implementations.

## `wotex_runtime`

Once a validated TD exists, Tracker uses Runtime ConsumedThing/ExposedThing mechanics for portable interaction planning. Tracker supplies consumer-owned transports, credentials, supervision and application state according to Runtime contracts.

Long-lived observations/events remain caller-supervised. Tracker may provide host supervision helpers but must not alter Runtime lifecycle semantics.

## bindings

HTTP and MQTT forms use their dedicated WoTEx bindings when compatible. Tracker-specific cellular/AVL/advertisement decoding happens before WoT exposure and is not mislabeled as an HTTP/MQTT binding.

A generic BLE binding/discovery package is a likely future repository once the PoC proves reusable semantics. Candidate name: `wotex-binding-ble`. It should be created only when a protocol-neutral contract can be stated independently of tracking.

A LoRaWAN repository should likewise be created only if there is a reusable WoT binding/network-server abstraction beyond tracker-specific payload profiles. LoRaWAN radio/network semantics must not be forced into core merely to satisfy this PoC.

## `wotex_directory`

Tracker may publish validated, authorized instance TDs and query Thing Models/TDs through Directory contracts. Unresolved discovery evidence is not Directory content.

## `wotex_continuum`

Continuum is the preferred future boundary for moving normalized observations/actions across edge/cloud placement when its contracts fit. Tracker must not build a competing generic edge/cloud replication substrate.

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
