# WTR.07 Headless service, machine interfaces and UI boundary

## Status

Accepted target contract. No implementation claim.

## Decision

Tracker is **headless first, not UI-less**.

The core/library and service interfaces are the product boundary. A reference UI is valuable to prove scan -> evidence -> Thing workflows, but it must be a replaceable consumer.

## Public Elixir facade

The stable public entry point SHOULD be a small facade under `Wotex.Tracker` plus immutable domain values. Protocol/scanner implementation modules remain internal or adapter-facing.

Initial public operations SHOULD cover:

```elixir
{:ok, observation} = Wotex.Tracker.observe(input, context)
{:ok, resolution} = Wotex.Tracker.resolve(observation, catalogue, context)
{:ok, evidence} = Wotex.Tracker.decode(resolution, context)
{:ok, td} = Wotex.Tracker.materialize(evidence, deployment, context)
```

The exact arities may change before implementation stabilizes, but the semantic boundary is fixed: capture facts -> resolve profile -> decode evidence -> materialise validated WoT value.

The facade MUST also expose bounded query/control operations for host applications:

- start/stop an explicitly configured discovery session through a caller-owned provider;
- submit imported/network observations;
- inspect unresolved, candidate and resolved discovery results;
- inspect evidence and profile match reasons;
- enroll or associate a device through explicit operator evidence;
- materialise and validate a TD;
- read canonical tracker state/history through caller-selected storage ports;
- subscribe to deterministic Tracker events through caller-owned supervision;
- inspect transport-policy decisions; and
- invoke authorized Thing interactions through WoTEx Runtime rather than a Tracker-specific execution stack.

## Public behaviours/ports

The first implementation SHOULD define narrow behaviours for:

- `DiscoveryProvider` — emits bounded observations and owns no canonical state;
- `ProfileRegistry` — returns immutable/versioned profiles for one resolution run;
- `Store` — optional consumer-owned persistence for observations/evidence/state;
- `Clock` — explicit time input for freshness/rule evaluation; and
- `IdentityStore` or equivalent — consumer-owned stable association/enrollment state where persistence is required.

A decoder and fingerprint SHOULD preferably be pure values/functions or profile callbacks rather than long-lived processes.

## Stable values

Public values SHOULD include `Observation`, `Evidence`, `DeviceProfile`, `Capability`, `Resolution`, `PositionEvidence`, `TransportDecision`, and typed `Error` values plus upstream WoTEx TD/TM values.

They MUST NOT expose BlueZ structs, CoreBluetooth structs, socket connection processes, Teltonika parser internals, LoRaWAN network-server SDK types, Phoenix structs, database records, or Refpath-specific types.

## Service host

A reference headless host MAY provide HTTP/JSON and streaming APIs. It SHOULD be suitable for a Phoenix/Svelte app, mobile app, CLI, Home Assistant integration, fleet backend, or Refpath connector without privileged in-process access.

The host MUST NOT expose raw credentials, LoRaWAN keys, SIM secrets, BLE pairing secrets, or stable private identifiers by default.

Machine endpoints SHOULD mirror the public domain operations rather than invent a second model: observations, resolutions, evidence, Things, current state, events and authorized actions.

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

Internal scanner libraries, BLE stacks, cellular socket implementations and vendor protocol libraries MUST NOT leak into the stable public API. Stable values are Tracker domain values plus WoTEx values.
