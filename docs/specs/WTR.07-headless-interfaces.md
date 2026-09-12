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

These are planned API sketches, not executable examples today. The semantic boundary is fixed: capture facts -> resolve profile -> decode evidence -> materialise validated WoT value. `observe/2` admits supplied data; it does not scan or read a clock. `resolve/3` returns `{:ok, %Resolution{status: :resolved | :unknown | :ambiguous, ...}}` for valid input, with candidates/reasons and the immutable catalogue identity. Candidate-only evidence yields `:unknown` with reason `:insufficient_evidence` under WTR.02. Malformed input, conflicting catalogue definitions and exhausted limits return `{:error, %Error{}}`. `decode/2` refuses unresolved input and consumes the selected snapshot; `materialize/3` refuses incomplete/mismatched evidence. No stage reads a newer registry snapshot implicitly.

Later implemented host capabilities MUST expose corresponding bounded operations; these are outside the pure milestone:

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

The pure milestone takes immutable values and explicit time/identity inputs directly. Later integrations introduce only the narrow behaviours required by real interchangeable providers:

- `DiscoveryProvider` — emits bounded observations and owns no canonical state;
- `ProfileRegistry` — returns immutable/versioned profiles for one resolution run;
- `Store` — optional consumer-owned persistence for observations/evidence/state;
- `Clock` — explicit time input for freshness/rule evaluation; and
- `IdentityStore` or equivalent — consumer-owned stable association/enrollment state where persistence is required.

A decoder and fingerprint are pure values/functions or trusted profile callbacks, never processes for code organization. A `Clock` behaviour is unnecessary when passing an integer suffices. A profile registry returns a complete immutable snapshot; it is not consulted separately at every pipeline stage. Store and identity-association behaviour signatures are fixed with the host transaction acceptance, not pre-built as generic CRUD abstractions.

## Stable values

First-slice values are `Observation`, `Evidence`, `DeviceProfile`, `Capability`, `Resolution` and typed `Error`, plus upstream WoTEx TD/TM values. `PositionEvidence` and `TransportDecision` are introduced with their later implemented capabilities.

They MUST NOT expose BlueZ structs, CoreBluetooth structs, socket connection processes, Teltonika parser internals, LoRaWAN network-server SDK types, Phoenix structs, database records, or Refpath-specific types.

## Service host

A reference headless host MAY provide HTTP/JSON and streaming APIs. It SHOULD be suitable for a LiveView app, mobile app, CLI, Home Assistant integration, fleet backend, or Refpath connector without privileged in-process access.

The host MUST NOT expose raw credentials, LoRaWAN keys, SIM secrets, BLE pairing secrets, or stable private identifiers by default.

Machine endpoints SHOULD mirror the public domain operations rather than invent a second model: observations, resolutions, evidence, Things, current state, events and authorized actions.

Before shipping machine interfaces, version their exact request/result/error schemas, binary encoding, integer precision policy, pagination, subscription cursor/overflow behavior and idempotency semantics. Follow WTR.01 JSON admission and WTR.06 commit outcomes. Expected boundary errors have stable codes/paths and bounded redacted details, not inspected exception text. Protocol/scanner absence returns an explicit unsupported/unavailable result rather than a successful empty scan.

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

A reference UI uses Phoenix LiveView/HEEx under `hosts/workbench` or a shared inert UI boundary used by an explicitly started Nerves host. WTR.14 separates bootable firmware from the library and defines headless/UI-enabled acceptance. The UI should show:

- nearby observations without pretending they are trusted Things;
- fingerprint evidence and candidate profiles;
- resolved capabilities;
- generated TD/TM relationship;
- current Properties/Events;
- privacy/security state;
- transport status and fallback decisions; and
- optional AI investigation clearly separated from deterministic truth.

## Persistence

Stateful interfaces accept caller-owned persistence ports only when implemented. Pure tests pass immutable state directly. The first reference host may use per-instance volatile state; ETS requires explicit ownership and consistency rules and provides no durability. SQLite is an optional later host adapter after WTR.06 crash/transaction acceptance. PostgreSQL or other stores belong to deployments. No store library is a pure-core dependency.

## API stability

Internal scanner libraries, BLE stacks, cellular socket implementations and vendor protocol libraries MUST NOT leak into the stable public API. Stable values are Tracker domain values plus WoTEx values.
