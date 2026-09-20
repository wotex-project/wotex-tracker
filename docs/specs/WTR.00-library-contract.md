# WTR.00 Library and application boundary

## Status

Implemented for the reusable core and package boundary: `wotex_tracker` is an
inert, headless library with explicit inputs, deterministic domain operations and
no application callback, while service, browser, mobile and Nerves consumers live
in separate packages/hosts. This does not claim completion of the product,
physical adapters, hardware qualification or distribution gates required below.
See the [implementation plan](../plans/software-implementation.md) and
[executed evidence](../evidence/implementation.md#foundation--2026-09-15).

## Purpose

`wotex_tracker` is the reusable tracking/sensing domain library of the WoTEx Tracker product. Physical devices with different discovery and transport mechanisms become evidence-backed W3C WoT Things without making a UI, vendor cloud, radio technology, database, or AI engine part of the semantic core.

The complete product MUST deliver an independently usable headless service, a
full tracking application, bootable Pi 5 service/control panel, mobile companion
and interactive/prompted analytics under WTR.07/14/15/16. These are required
deliverables, optional installations for library consumers. A partial software
milestone is not product completion. Missing dependency capabilities, funding or
hardware evidence block the affected gate; they do not remove its requirement.

## Required boundary

The reusable core MUST be headless and embeddable. It MUST NOT require Phoenix, Svelte, a browser, a mobile application, Refpath, a database server, Docker, a LoRaWAN deployment, a cellular operator, or a specific hardware vendor merely to construct and test its deterministic domain values.

The package MAY provide explicitly started runtime components for scanners, ingresses, observations and Thing publication. It MUST NOT define an application startup callback, start a Tracker supervision tree on dependency load, install global handlers, or read ambient configuration to choose a provider. Caller-supplied options and child specifications control each independent instance. Radios, listeners, Bluetooth adapters and data transmission require explicit calls. WTR.13 defines the Elixir/OTP floor; host applications are separate consumers.

## First implementation boundary

The first implementation slice is deliberately narrower than the complete product:

1. immutable `Observation`, `Evidence`, `DeviceProfile`, `Capability`, `Resolution`, and typed error values;
2. pure deterministic fingerprint matching and profile resolution;
3. pure bounded decoder contracts plus fixture-driven RuuviTag Raw v2 decoding;
4. deterministic Thing Model selection and TD materialisation inputs;
5. validation through upstream `wotex`;
6. an imported-fixture entry point using caller-supplied observations and an immutable catalogue; and
7. a stable headless facade that exposes those operations without leaking scanner/library implementation details.

This slice MUST NOT include a web UI, database dependency, Refpath integration, LoRaWAN requirement, cellular listener, generic Directory server, generic Continuum transport, or generic WoT Runtime replacement.

It does not require a clock, store, profile-registry process, scanner behaviour or application startup. Introduce a behaviour only when an implemented integration needs interchangeable providers. First-slice acceptance and later host gates are distinct in the implementation plan.

## Owned concepts

Tracker owns the vertical concepts that do not belong in protocol-neutral WoTEx core:

- bounded physical observations and observation provenance;
- physical-device fingerprints and candidate identity evidence;
- tracker/sensor device profiles and versioned decoders;
- capability evidence and confidence classification;
- canonical tracking-domain observation/state chosen by explicit consumer policy;
- profile-to-Thing-Model mapping and instance TD materialisation inputs;
- tracking-specific position evidence and deterministic source selection;
- transport preference/fallback policy descriptions;
- hardware qualification records and vendor-independence gates;
- anti-stalking/privacy controls specific to physical tracking deployments; and
- application/service orchestration across those boundaries, isolated in hosts.

## Not owned

Tracker MUST NOT fork or reimplement:

- TD/TM parsing, validation, canonical WoT values or generic DataSchema semantics owned by `wotex`;
- generic ConsumedThing/ExposedThing execution, Form selection, credentials ports, transport ports, subscriptions, or retry classification owned by `wotex_runtime`;
- generic HTTP/MQTT/BLE/CoAP/Thread/BACnet/Matter/Modbus/OPC UA protocol and binding semantics owned by their respective packages;
- Thing Description Directory registration, retrieval, listing, expiry, patch, lifecycle-event or introduction semantics owned by `wotex_directory`;
- generic host-neutral continuum wire values, compatibility, action-intent/result or delivery-state schemas owned by `wotex_continuum`;
- generic numerical WoT conversion contracts owned by `wotex_nx`; or
- agent/model/tool orchestration owned by Refpath.

Generic BLE/GATT belongs to the existing `wotex_ble` package. A Tracker discovery provider may adapt physical observations, but MUST NOT duplicate that package's protocol execution or Form mapping. A missing generic capability is an upstream integration requirement, not a reason to create another BLE repository. Other graduation decisions require concrete reuse evidence and an ownership review under WTR.10.

## Determinism floor

For identical bounded input observations, profile catalogue, configuration, and explicit time/identity inputs, matching, decoding, capability resolution, TD materialisation, rule evaluation, and transport-policy decisions MUST be deterministic.

No LLM or external AI service may participate in the acceptance path for device identity, decoded measurements, capability truth, alarm truth, safety policy, or authorization.

## UI boundary

The authoritative product surface is a headless Elixir API plus machine-readable
interfaces. The first-party application MUST consume the same authorized service
boundary available to third-party applications. WTR.15 defines shared LiveView
screens and native WebView composition; WTR.14 defines the local Pi display.
UI-only state MUST NOT become canonical device or tracking state. An application
can start its declared services at boot without changing the library's inert
installation contract. Replacing a frontend does not require replacing the engine.

## Vendor independence

A profile MUST NOT be promoted as supported when normal operation requires a mandatory manufacturer cloud, opaque SaaS API, non-transferable tenant, or vendor-controlled identity service. Optional vendor tooling is permitted only when a fully operator-controlled data path is also qualified.
