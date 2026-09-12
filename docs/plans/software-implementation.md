# Software implementation sequence

This plan orders implementation by contract dependency and evidence value. It does not convert target specifications into implementation claims.

## Phase 0 — repository/package foundation

- Mirror WoTEx project hygiene: Mix package, formatter, test helper, CI, LICENSE, NOTICE, SECURITY, CONTRIBUTING and changelog.
- During coordinated development, use explicit `WOTEX_PATH_DEPS=1` development dependencies as specified in WTR.10; the pure milestone requires only `wotex`. Never auto-discover adjacent repositories.
- Add catalogue validation and spec-link checks.
- Define typed errors and finite limits before live scanners/listeners.

## First implementation boundary

The first code milestone ends at a validated TD produced from deterministic physical evidence. It includes only:

- immutable domain values for observations, evidence, profiles, capabilities, resolution results and typed errors;
- pure fingerprint/profile resolution;
- pure bounded decoder contracts;
- fixture-backed RuuviTag Raw v2 decoding;
- explicit identity strategy inputs with no persistence assumption;
- reusable Thing Model selection;
- deterministic instance TD materialisation through upstream `wotex` validation;
- caller-owned discovery/profile/clock ports; and
- a narrow `Wotex.Tracker` headless facade.

It explicitly excludes Phoenix/Svelte UI work, Refpath, LoRaWAN, cellular listeners, SQLite/PostgreSQL requirements, a generic Directory host, Continuum transport, and replacement implementations of Wotex Runtime or protocol bindings.

The milestone is complete when an imported Ruuvi fixture can traverse:

```text
Observation -> profile resolution -> decoder evidence -> capabilities -> Thing Model -> validated TD
```

with zero processes required and deterministic output for fixed inputs.

## Phase 1 — pure domain floor

Implement immutable values and pure functions for Observation, Evidence, DeviceProfile, capability declarations, fingerprint predicates, profile resolution, identity strategies and decoder results.

Acceptance: fixtures can resolve/deny/ambiguously match without starting an application or touching hardware.

## Phase 2 — Thing Models and materialisation

Add generic tracker/sensor Thing Models and deterministic materialisation into validated `wotex` TD values. Prove that capabilities, identity and deployment forms produce a valid TD and that unsupported capabilities do not appear.

Acceptance: materialisation is deterministic and validated by upstream `wotex`.

## Phase 3 — passive BLE proof

Implement a caller-owned BLE discovery provider behind a narrow port. Start with imported captures, then Linux/macOS live scanning as separately qualified adapters.

Add RuuviTag profile/decoder using authoritative open format documentation and real captures.

Acceptance: real advertisement -> evidence -> capabilities -> validated TD -> Runtime property observation.

## Phase 4 — headless host

Add CLI and minimal HTTP/streaming host consuming the same public API. Use in-memory/SQLite host persistence without making either part of core semantics.

Acceptance: another application can scan/inspect/materialise/observe without importing internal scanner modules.

## Phase 5 — finished cellular tracker

Implement a bounded direct listener and Teltonika AVL profile/decoder for a qualified finished tracker (TAT140 first target, ATC700 second). Configure real hardware to operator infrastructure and capture hardware evidence.

Acceptance: real tracker -> direct ingress -> acknowledgement -> normalized position/motion/battery -> same Thing model family -> WoT interface.

## Phase 6 — deterministic tracking policy

Implement position evidence, freshness, movement/geofence/heartbeat state, event-time handling, deduplication and explicit transport-policy values. Add property-based and replay tests.

## Phase 7 — optional LoRaWAN lane

Select hardware only after WTR.09 qualification. Integrate through an operator-controlled LoRaWAN network server. Keep device payload profiles in Tracker; graduate reusable generic network-server/WoT semantics only when proven.

## Phase 8 — existing BLE owner integration review

Review any remaining scanner/GATT integration against the existing `wotex_ble` owner. Contribute missing generic contracts upstream when reuse is demonstrated, preserving Tracker profiles. This review does not create a second BLE package or imply passive scanning is already available.

## Phase 9 — optional Refpath

Expose validated Things to Refpath through a public connector/plugin boundary. Demonstrate read-only investigation first, then policy-gated Actions. No Refpath dependency enters core Tracker.

## Phase 10 — reference workbench

Only after the headless API is stable, add a replaceable reference UI showing discovery evidence, profile resolution, TDs, current state, events, privacy status and optional AI investigation.

## Release gates

Before a first package release:

- warnings-as-errors compile, formatting and full unit/property suite;
- dependency/audit/license checks matching WoTEx organization policy;
- no credential or stable-identifier leaks in logs/fixtures;
- real BLE hardware evidence;
- at least one finished cellular tracker direct-to-operator evidence lane;
- cross-repository compatibility with pinned/released WoTEx dependencies;
- documentation distinguishes target, fixture, integration and hardware-qualified claims.
