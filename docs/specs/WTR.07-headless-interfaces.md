# WTR.07 Headless service, machine interfaces and UI boundary

## Status

Implemented for the pure facade and the explicit headless service: authenticated
HTTP/JSON, OpenAPI, resumable SSE, durable SQLite state, bounded history and
analytics, Runtime Property reads/observation, packaged CLI, bundled Darwin and
Linux ARM64 releases, a local OCI image and an independent Rust consumer have
executable evidence. The optional cellular listener now reports its configured
host composition without claiming physical readiness. Live BLE scanning,
physical Action adapters, hardware qualification, public artifact distribution
and the complete WTR.15 application remain open. See the
[service contract](../contracts/service-v1.md) and
[executed evidence](../evidence/implementation.md).

## Decision

Tracker is **headless first, not UI-less**.

The library and authorized service interfaces are the stable product boundary.
The complete first-party application is required under WTR.15 and remains a
replaceable consumer. UI, native shell and firmware installation are choices
for deployments, not optional implementation of required product workflows.

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

The service host MUST provide versioned HTTP/JSON operations, an OpenAPI document
and resumable Server-Sent Events (SSE). These interfaces MUST support the complete
application workflows without privileged in-process access. A non-Elixir client
can enroll, submit/query observations, inspect state/history, manage policies,
query analytics and invoke authorized interactions through that boundary.

The host MUST NOT expose raw credentials, LoRaWAN keys, SIM secrets, BLE pairing secrets, or stable private identifiers by default.

Machine endpoints MUST mirror the public domain operations: observations,
resolutions, evidence, Things, enrollment, current state/history, policies,
events, analytics and authorized interactions. WTR.16 owns the query/result
schema; the service does not expose arbitrary storage queries.

Before shipping machine interfaces, version their exact request/result/error schemas, binary encoding, integer precision policy, pagination, subscription cursor/overflow behavior and idempotency semantics. Follow WTR.01 JSON admission and WTR.06 commit outcomes. Expected boundary errors have stable codes/paths and bounded redacted details, not inspected exception text. Protocol/scanner absence returns an explicit unsupported/unavailable result rather than a successful empty scan.

The first machine surface uses `/api/v1`, JSON success/error envelopes and a
separately versioned event envelope. Publish an OpenAPI revision supported by the
selected validator/client tools; pin that revision and validate actual requests
and responses against it. Operation IDs, error codes, query/result schemas and
event types are public contracts. Adding a frontend cannot change their meaning.

IDs and opaque cursors are strings. Browser-facing numeric fields declare exact
ranges; wider protocol values use an explicit schema-defined lossless projection.
Raw evidence exports preserve WTR.01 native types/bytes and must not pass through
a lossy browser parse/re-encode path. Identity/generation tokens are issued by
the service rather than recomputed from JavaScript numbers. Test `1` versus `1.0`,
zero/false/null and counters beyond JavaScript's exact integer range end to end.

Every mutation has a caller-scoped idempotency identity and a documented retry
contract. Reuse with different admitted content is a conflict. Conditional writes
include the expected generation. Results expose WTR.06 commit/publication state;
an operation-status lookup resolves retained unknown outcomes without executing
the operation again. Retention expiry is explicit. Never retry a physical Action
solely because the caller timed out.

Paginated reads bind scope, filters and sort order to a committed snapshot.
Subscriptions bind principal/scope, source generation and event cursor; deliver
stable event IDs with at-least-once replay within retained history. Clients
deduplicate. The snapshot-to-stream handoff MUST neither miss commits nor present
a mixed generation. Expired/invalid cursors require an explicit resnapshot, not
an empty success or silent jump to the latest event. Retention and overflow are
visible, and slow clients cannot retain unlimited server memory.

Authenticate requests and streams without credentials in URLs. Cookie sessions
use CSRF/origin controls; non-browser callers use scoped credentials over TLS.
Authorization applies at admission, query and delivery time. Revoke existing
streams when access changes and re-authorize resumed cursors; signing a cursor
does not grant access. Credential exchange and TLS termination are host-owned.

Before listener implementation, fix finite request/body/batch/page/event sizes,
concurrent request/stream limits, retention, deadlines and shutdown budgets under
WTR.13. Enforce input bounds before parsing and output bounds before publication.

## Standalone service and sidecar distribution

Ship a headless Mix release with bundled ERTS and an OCI image for declared Linux
architectures. A consumer MUST be able to start the service, configure persistent
storage/credentials, use HTTP/SSE and stop it without installing Elixir, Erlang,
Phoenix, a notebook, an AI service or a compiler. Artifacts are OS/architecture
specific; a single release is not a universal executable.

The headless service may use Plug/Bandit for HTTP without requiring Phoenix or
LiveView. The UI-enabled host adds the shared web package. Root and service-only
consumers compile with all UI/mobile/Nerves/private integrations absent. Expose
separate liveness, readiness and capability/status results: a running endpoint
does not mean writable storage or qualified device ingress is ready.

The host owns explicit bind addresses, TLS/proxy policy, data paths, secret input,
shutdown and resource budgets. Loopback sidecar deployment still uses scoped
authorization; remote access requires configured networking and authentication.
No public tunnel, vendor account or external discovery service is implicit.
Stopping/restarting the UI must not stop ingestion or corrupt admission state.

Acceptance requires a clean release/image consumer and an independent non-Elixir
HTTP/SSE client exercising enrollment, observation admission, query/history,
events, reconnection, authorization and operation outcomes. Test signal shutdown,
restart, unwritable/full storage, API version mismatch, duplicate mutations,
snapshot/stream races and revoked access. Documented commands must execute against
the built artifact. Building does not authorize publishing an image or release.

## CLI

A CLI MUST prove the complete non-UI flow, conceptually:

```console
wotex-tracker scan --ble
wotex-tracker candidates
wotex-tracker inspect DEVICE
wotex-tracker materialize DEVICE
wotex-tracker things
wotex-tracker observe THING temperature
```

Command names are illustrative until implementation stabilizes.

## Application UI

A shared Phoenix LiveView/HEEx application under WTR.15 MUST provide the complete
tracking workflows. WTR.14 defines Pi display/firmware acceptance and WTR.16
defines prompted queries and dynamic graphs. Its inspection surfaces also show:

- nearby observations without pretending they are trusted Things;
- fingerprint evidence and candidate profiles;
- resolved capabilities;
- generated TD/TM relationship;
- current Properties/Events;
- privacy/security state;
- transport status and fallback decisions; and
- optional AI investigation clearly separated from deterministic truth.

## Persistence

Stateful interfaces accept explicitly configured persistence components. Pure
tests pass immutable state directly. Volatile storage is a development/test
profile and cannot satisfy product durability. WTR.06 owns the local SQLite
target, crash/transaction acceptance and alternative-store boundary. ETS provides
no durability. No store library is a pure-core dependency.

## API stability

Internal scanner libraries, BLE stacks, cellular socket implementations and vendor protocol libraries MUST NOT leak into the stable public API. Stable values are Tracker domain values plus WoTEx values.
