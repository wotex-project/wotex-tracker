# ADR 0001: Headless core with complete replaceable applications

Status: Accepted

## Decision

`wotex_tracker` is an inert domain library. The product supplies a required
standalone service and complete applications through isolated hosts. Elixir APIs
and versioned machine interfaces are authoritative. Shared LiveView screens run
in the web host, Pi kiosk and native mobile WebView, with explicit service access.

## Why

The project must support mobile, LiveView, CLI, fleet, embedded and AI consumers. Making a UI canonical would couple device semantics and lifecycle to one application shape and weaken the WoT intermediary proof.

## Consequences

- scanning/listening is explicit caller-owned runtime work;
- canonical state is not held in browser/UI state;
- the CLI must be able to demonstrate the full PoC;
- a UI can be replaced without changing profiles or Thing semantics; and
- UI convenience may not bypass evidence/security boundaries.

Applications and bootable firmware own startup callbacks and explicitly supervise
services; the root library does not. WTR.07/14/15/16 define required product gates
separately from core software acceptance. Consumers may omit every UI component
without losing the headless contract. Dependency limitations cannot waive a
required workflow or turn a partial application into an accepted product.
