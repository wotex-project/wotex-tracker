# ADR 0001: Headless core with replaceable reference UI

Status: Accepted

## Decision

`wotex_tracker` is a headless-first library/service. The authoritative interfaces are Elixir domain APIs and machine interfaces. A reference UI may be shipped later as an isolated host that consumes those same interfaces.

## Why

The project must support mobile, LiveView, CLI, fleet, embedded and AI consumers. Making a UI canonical would couple device semantics and lifecycle to one application shape and weaken the WoT intermediary proof.

## Consequences

- scanning/listening is explicit caller-owned runtime work;
- canonical state is not held in browser/UI state;
- the CLI must be able to demonstrate the full PoC;
- a UI can be replaced without changing profiles or Thing semantics; and
- UI convenience may not bypass evidence/security boundaries.

The optional reference UI uses Phoenix LiveView/HEEx. A bootable Nerves Pi 5 host may own an application callback and explicitly supervise Tracker services; the root library does not. WTR.14 defines firmware and UI acceptance separately from the pure package.
