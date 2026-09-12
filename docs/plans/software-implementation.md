# Software implementation sequence

This plan orders implementation by contract dependency and evidence value. It does not convert target specifications into implementation claims.

## Phase 0 — repository/package foundation

- Mirror WoTEx project hygiene: Mix package, formatter, test helper, CI, LICENSE, NOTICE, SECURITY, CONTRIBUTING and changelog.
- During coordinated development, use explicit sibling path dependencies for `wotex` and `wotex_runtime`; never auto-discover adjacent repositories.
- Add catalogue validation and spec-link checks.
- Define typed errors and finite limits before live scanners/listeners.

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

## Phase 8 — generic BLE graduation

Review the BLE scanner/GATT interaction boundary. If it is useful to non-tracker Things, create `wotex-binding-ble` and move generic protocol semantics there without breaking Tracker profiles.

## Phase 9 — optional RefPath

Expose validated Things to RefPath through a public connector/plugin boundary. Demonstrate read-only investigation first, then policy-gated Actions. No RefPath dependency enters core Tracker.

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
