# WTR.07 Headless service, machine interfaces and UI boundary

## Status

Accepted target contract. No implementation claim.

## Decision

Tracker is **headless first, not UI-less**.

The core/library and service interfaces are the product boundary. A reference UI is valuable to prove scan -> evidence -> Thing workflows, but it must be a replaceable consumer.

## Elixir API

The public API SHOULD expose bounded operations for:

- starting/stopping explicitly configured discovery sessions;
- submitting imported/network observations;
- listing unresolved/candidate/resolved discoveries;
- inspecting evidence and profile matches;
- enrolling/associating a physical device;
- materialising/validating a TD;
- reading current normalized state and history through a caller-selected store;
- subscribing to deterministic events;
- inspecting transport policy decisions; and
- invoking authorized Thing interactions through WoTEx Runtime.

## Service host

A reference headless host MAY provide HTTP/JSON and streaming APIs. It SHOULD be suitable for a Phoenix/Svelte app, mobile app, CLI, Home Assistant integration, fleet backend, or RefPath connector without privileged in-process access.

The host MUST NOT expose raw credentials, LoRaWAN keys, SIM secrets, BLE pairing secrets, or stable private identifiers by default.

## CLI

A CLI SHOULD prove the complete non-UI flow, conceptually:

```console
wotex-tracker scan --ble
wotex-tracker candidates
wotex-tracker inspect DEVICE
wotex-tracker materialize DEVICE
wotex-tracker things
wotex-tracker observe THING temperature
```

Command names are illustrative until implementation stabilizes.

## Reference UI

A reference UI MAY live under `hosts/workbench` or an equivalent isolated host. It should show:

- nearby observations without pretending they are trusted Things;
- fingerprint evidence and candidate profiles;
- resolved capabilities;
- generated TD/TM relationship;
- current Properties/Events;
- privacy/security state;
- transport status and fallback decisions; and
- optional AI investigation clearly separated from deterministic truth.

## Persistence

Core interfaces MUST accept caller-owned persistence ports. ETS/in-memory storage is sufficient for deterministic tests. SQLite is a preferred self-contained PoC host option. PostgreSQL or other stores belong to host deployments, not the core contract.

## API stability

Internal scanner libraries, BLE stacks, cellular socket implementations and vendor protocol libraries MUST NOT leak into the stable public API. Stable values should be Tracker domain structs plus WoTEx values.
