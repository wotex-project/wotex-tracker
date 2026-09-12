# Primary source provenance

This file records the standards/repository baseline used to write the initial WTR target contracts. It is not executed conformance evidence.

Baseline date: 2026-09-12.

## W3C Web of Things

The design is intentionally aligned with the WoTEx ecosystem's existing standards baseline rather than creating tracker-specific alternatives. Relevant W3C families include Thing Description 1.1, Thing Model semantics, WoT Discovery, WoT Architecture, WoT Security and Privacy guidance, and binding-template/binding specifications used by installed WoTEx packages.

Exact normative revisions used by code MUST be pinned in the owning upstream WoTEx package and referenced here rather than duplicated. Tracker consumes those contracts.

## WoTEx repositories inspected

Initial WTR contracts were shaped against the intended boundaries documented by:

- `wotex-project/wotex`
- `wotex-project/wotex-runtime`
- `wotex-project/wotex-binding-http`
- `wotex-project/wotex-binding-mqtt`
- `wotex-project/wotex-directory`
- `wotex-project/wotex-continuum`
- `wotex-project/wotex-nx`
- `wotex-project/wotex-lab`
- `wotex-project/wotex-matter`
- `wotex-project/wotex-modbus`
- `wotex-project/wotex-opcua`

Tracker specifications intentionally follow the WoTEx convention of numbered target contracts, an index, a machine-readable catalogue, provenance, decisions and an implementation plan. Implementation evidence remains separate.

## Refpath

The optional AI boundary was checked against the current Refpath design in which the runtime owns agent sessions, tool policy, durable execution, model routing, verification/audit and recovery. WTR therefore exposes validated WoT affordances to Refpath optionally; Refpath does not become the deterministic IoT/tracking engine.

Because Refpath is not an OSS dependency of Tracker, no private Refpath source is copied into this repository.

## Updating

Any standards claim that materially changes matching, TD materialisation, security, discovery or binding semantics requires a dated provenance update and review of the owning WTR contract.