# ADR 0001: Headless core with replaceable reference UI

Status: Accepted

## Decision

`wotex_tracker` is a headless-first library/service. The authoritative interfaces are Elixir domain APIs and machine interfaces. A reference UI may be shipped later as an isolated host that consumes those same interfaces.

## Why

The project must support arbitrary mobile, Phoenix/Svelte, CLI, fleet, embedded and AI consumers. Making a UI canonical would couple device semantics and lifecycle to one application shape and weaken the WoT intermediary proof.

## Consequences

- scanning/listening is explicit caller-owned runtime work;
- canonical state is not held in browser/UI state;
- the CLI must be able to demonstrate the full PoC;
- a UI can be replaced without changing profiles or Thing semantics; and
- UI convenience may not bypass evidence/security boundaries.