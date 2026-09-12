# WTR.00 Library and application boundary

## Status

Accepted target contract. No implementation claim.

## Purpose

`wotex_tracker` is a generic tracking/sensing vertical built on WoTEx. It proves that physical devices with different discovery and transport mechanisms can become evidence-backed W3C WoT Things without making a UI, vendor cloud, radio technology, database, or AI engine part of the semantic core.

## Required boundary

The reusable core MUST be headless and embeddable. It MUST NOT require Phoenix, Svelte, a browser, a mobile application, RefPath, a database server, Docker, a LoRaWAN deployment, a cellular operator, or a specific hardware vendor merely to construct and test its deterministic domain values.

The package MAY provide supervised runtime components for scanners, ingresses, profile registries, observations, and Thing publication. Starting the dependency MUST NOT silently start radios, open listeners, claim Bluetooth adapters, contact vendor services, or transmit device data. Resource ownership is caller-configured and explicit.

## Owned concepts

Tracker owns the vertical concepts that do not belong in protocol-neutral WoTEx core:

- bounded physical observations and observation provenance;
- physical-device fingerprints and candidate identity evidence;
- tracker/sensor device profiles and versioned decoders;
- capability evidence and confidence classification;
- profile-to-Thing-Model mapping and instance TD materialisation inputs;
- tracking-specific position evidence and deterministic source selection;
- transport preference/fallback policy descriptions;
- hardware qualification records and vendor-independence gates;
- anti-stalking/privacy controls specific to physical tracking deployments; and
- reference PoC orchestration across those boundaries.

## Not owned

Tracker MUST NOT fork or reimplement:

- TD/TM parsing, validation, canonical WoT values or generic DataSchema semantics owned by `wotex`;
- generic ConsumedThing/ExposedThing execution owned by `wotex_runtime`;
- generic HTTP/MQTT/Matter/Modbus/OPC UA binding semantics owned by their binding packages;
- Thing Description Directory semantics owned by `wotex_directory`;
- generic edge/cloud continuity owned by `wotex_continuum`;
- generic numerical/ML primitives owned by `wotex_nx`; or
- agent/model/tool orchestration owned by RefPath.

If implementation work reveals a reusable generic BLE WoT binding, generic discovery provider, or other protocol-neutral capability, that work SHOULD graduate to a dedicated WoTEx repository rather than remain tracker-specific. Tracker may host the first vertical adapter only while the generic boundary is still being proven.

## Determinism floor

For identical bounded input observations, profile catalogue, configuration, and explicit time/identity inputs, matching, decoding, capability resolution, TD materialisation, rule evaluation, and transport-policy decisions MUST be deterministic.

No LLM or external AI service may participate in the acceptance path for device identity, decoded measurements, capability truth, alarm truth, safety policy, or authorization.

## UI boundary

The authoritative product surface is a headless Elixir API plus machine-readable interfaces. A reference UI MAY be added under a separate host/application directory and MUST consume the same public service boundary available to third-party applications. UI-only state MUST NOT become canonical device or tracking state.

## Vendor independence

A profile MUST NOT be promoted as supported when normal operation requires a mandatory manufacturer cloud, opaque SaaS API, non-transferable tenant, or vendor-controlled identity service. Optional vendor tooling is permitted only when a fully operator-controlled data path is also qualified.
