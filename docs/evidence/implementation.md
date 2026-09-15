# Implementation evidence

This log distinguishes implemented software from accepted delivery targets.
No hardware, application, release distribution or conformance claim is made.

## Foundation — 2026-09-15

Implemented: inert root Mix package, Apache-2.0 license/notices, contribution and
security guidance, bounded redacted error contract, duplicate-preserving YAML
catalogue validation, evidence/reference/delivery graph checks and local links.
The configured local gate runs formatting, warnings-as-errors compilation, full
ExUnit plus 95% coverage, strict Credo, Dialyzer, warnings-as-errors ExDoc,
dependency audit, unused lock entries and dependency license review.

Verification environment: Darwin arm64. Required lanes are Elixir 1.18.4 /
OTP 27.3.4.15 and Elixir 1.20.4 / OTP 29.0.4. Both complete local gates passed:
7 tests, 0 failures, 100% production line coverage; compiler, formatter, strict
Credo, Dialyzer, docs, catalogue/links, dependency audit/licenses, unused lock
entries and archive inspection passed. Commands use `MIX_ENV=test`, with the
newer lane isolated under `MIX_BUILD_PATH=_build/otp29/test`. Third-party test
and documentation dependencies emit deprecation warnings on their initial OTP 29
compilation; no suppression was added. Root warnings-as-errors compilation passes.
The only core runtime dependency is `wotex` plus OTP crypto. Development uses
`WOTEX_PATH_DEPS=1` with `../wotex` at
`eadc6c9f9c285faf9324b8a7396a001381098b6c` (clean at inspection).
Other dependencies are pinned in `mix.lock`; yamerl's historical `BSD 2-Clause`
label was checked against its LICENSE and normalized to SPDX `BSD-2-Clause`.

`mix hex.build` succeeds without the development switch. Its inspected manifest
contains the explicit root library, documentation, license/notices and model
directory, excluding hosts, dependencies, build state, tests and private inputs.
The metadata requires ordinary `wotex ~> 0.1.0`; no path dependency is published.

Unpassed gates: `https://hex.pm/api/packages/wotex` returned HTTP 404 on this date.
Locked/fresh/minimum published-package consumers cannot resolve the required
release. Source-cohort checks cannot establish published-package compatibility.
No production path switch or dependency-constraint override is allowed.

The current `wotex_ble` public API provides connected GATT discovery, with no
passive advertisement scanning entry point. Live BLE is blocked on that upstream
contract plus qualified controller/hardware evidence. Imported observations do
not depend on a scanner. No sibling repository was modified.

## WTR.01 software values — 2026-09-15

Implemented bounded Observation, Evidence, EvidenceBundle, Identity and Limits
values. See [the API guide](../guides/observations.md). Native JSON and canonical
Base64 exports preserve type identity. Complete content digests, explicit
UUIDv4 pseudonymous associations, strict duplicate handling, bounded graph
lineage and aggregate claim admission are exercised independently of profiles.

Both required runtime lanes passed with 2 properties and 20 tests, 0 failures,
99.5% production line coverage. Each ran all configured checks and inspected
archive contents. The upstream source revision remained unchanged and clean.
No profile resolution, decoder, TD pipeline, live adapter or hardware is claimed
by this slice. Published-package consumer gates remain unpassed as above.

## WTR.02 resolution and WTR.03 profile values — 2026-09-15

Implemented closed declarative predicates, immutable DeviceProfile/Catalogue and
Resolution values. See [the profile guide](../guides/profiles.md). Matching retains
all candidates, rejects exhaustion, preserves equal-best ambiguity and does not
invoke decoders. Weak name/radio evidence cannot create an eligible profile.

Both required runtime lanes passed the complete local gate: 3 properties and
25 tests, 0 failures, 99.7% production line coverage. Cases include 255/256/257
profiles, 31/32/33 predicates, candidate overflow, full revision identity,
permutations, strict numeric matching, escaped pointers and forged selections.

An elapsed-time diagnostic on the floor runtime used 256 profiles, 32 identical
predicates each and 50,000 bytes of source metadata. Setup was excluded; zero
warmup, one caller, five sequential samples. Before removing repeated admission
from internal predicate execution, samples were 1,511,096–1,574,702 microseconds;
afterwards 56,166–62,081 microseconds. Public boundaries still admit complete
inputs. Reproduce the latter using `scripts/bench_resolution.exs` with `MIX_ENV=test`.
These are diagnostic timings, not an SLA, allocation measurement or peak RSS.

Capabilities, profile-specific decoding, materialisation and hardware remain
subsequent acceptance work. No new protocol integration or release compatibility
is claimed by this batch.

## WTR.03 RAWv2 and capability evidence — 2026-09-15

Implemented pure RAWv2 profile/decoder, native Measurement and readable Capability
values, and explicit version-bound Decoder callbacks. The
[decoder guide](../guides/ruuvi.md) and
[fixture provenance](../provenance/ruuvi-raw-v2-fixtures.md) record the exact source,
transformations, units and limitations. Four independent published vectors and
synthetic mixed/zero/malformed cases exercise all fields. Capabilities survive
unavailable samples; no identity authentication, movement event or battery
percentage is inferred. Callback shapes, limits, revision mismatch, unresolved
selection and exception propagation are tested.

Both required runtime lanes passed the complete local gate: 4 properties and
32 tests, 0 failures, 99.1% production line coverage. Archive inspection includes
the decoder, domain values and source provenance. The Ruuvi lane is fixture
software evidence only; live BLE, physical hardware and the TD/Runtime path
remain unpassed. No live scanner was added or sibling protocol owner modified.

## WTR.04 materialisation and public facade — 2026-09-15

The first pure imported-fixture-to-TD software milestone is implemented. The
[materialisation guide](../guides/materialisation.md) describes explicit model,
identity, decoder, evidence and deployment inputs. The archive includes the
self-contained environmental Thing Model. Candidates enter upstream TM and TD
constructors with validation enabled. A fixed independently assembled TD fixture
checks exact canonical output. Missing samples preserve the TD while changing
private evidence identity. Optional omission, mandatory absence, escaped pointers,
unsupported model instructions, revision substitution, mapping conflicts,
security/Form failures, native extensions and resource limits are exercised.

Both required runtime lanes passed the complete local gate: 1 doctest,
4 properties and 45 tests, 0 failures, 97.9% production line coverage. No check,
coverage threshold or dependency constraint was weakened. Core source remains
`eadc6c9f9c285faf9324b8a7396a001381098b6c`.

`python3 scripts/source_consumer.py` additionally passed six isolated production
archive consumers: fresh resolution, locked resolution and selected compatible
minimum dependencies on both runtime lanes. The minimum set is Jason 1.4.0,
ex_json_schema 0.11.0 and Decimal 2.0.0, with unchanged Tracker/Wotex requirements
and no dependency overrides. The current set is Jason 1.4.5, ex_json_schema 0.11.5
and Decimal 3.1.1. Each consumer executed the full fixture-to-TD path from installed
archives, verified the packaged model, unknown resolution, no application callback,
no newly retained processes and absence of Runtime/UI/Nerves/Nx packages.

The upstream archive was prepared from an immutable clean source snapshot with
its unchanged lock after formatting, warnings-as-errors compilation, tests, docs
and archive build, following its own release-readiness instructions. Registry
signatures used temporary keys on an isolated loopback registry and a fresh
`HEX_HOME`; those resources were removed after execution. Public dependency
requirements were retained; `WOTEX_PATH_DEPS` was absent in every production
consumer. Archive SHA-256 identities and consumer lock digests are retained in
`verification/source-consumer.json`, outside the package to avoid self-reference.

These are local source-cohort artifacts, not publicly published releases. The
public `wotex` package remains unavailable and public-release compatibility is
unpassed. Synthetic Forms are not reachable-endpoint evidence. Phase 3 must still
prove actual host/Runtime/binding interaction and durability; physical BLE/cellular,
Pi, iPhone and integrated product gates remain unpassed.

## WTR.06 durable store foundation — 2026-09-15

`packages/tracker_service/` now implements the direct SQLite transaction boundary
pinned in the [service contract](../contracts/service-v1.md). The package has no
application callback; a caller starts its store explicitly. Root dependencies
and startup remain unchanged. The typed prepared-update seam is trusted host
code after authorization, not a remotely exposed CRUD or authenticated API.

Admission atomically writes observation identity/content, versioned records,
operation result, event intents and optional TD publication intent. Tests race
two independent SQLite writer connections, distinguish numeric/native values,
reject conflicting IDs and expected generations, preserve operation tombstones,
read immutable pages, and check snapshot-to-event continuity and expiry. A fresh
snapshot can resume a quiet scope with an old high-water event. Thirty-two
reserved helpers bound the writer queue; timeouts/caller death retain capacity
until the write finishes, and late replies are discarded.

Executed failure cases include pre-commit and stale-tombstone abort, process
crash before/after commit, lost acknowledgement, SQLite's actual page-limit full
error, busy writer locks, corrupt/foreign schemas, unsafe paths and failed startup.
Backup uses SQLite `VACUUM INTO`; a restored backup preserves observations,
deduplication and events. Publication persistence tests retain an uncertain
intent, reject stale confirmation and distinguish confirmed publication from
failed cleanup. No external publication client or physical power-cut durability
is claimed. Network filesystems, hostile same-user filesystem races, automatic
retention/purge and hardware power-loss tests remain unqualified.

The service uses Exqlite 0.40.0 / bundled SQLite 3.53.4, compiled from source with
Apple clang 21.0.0 (`clang-2100.3.34.2`), target `arm64-apple-darwin25.6.0`.
Its Hex lock fixes the driver/native source provenance. SHA-256 source identities:

- `sqlite3.c`: `b1dd5d74ec7f29055a6684fa06fb3c2f6821c87dd38f9a458dfd2e8a1db28189`
- `sqlite3.h`: `919e7f2e8ed1d8f56ac17b412b8971c76aa5d1a879752cc6058f75e7d5910e1d`

Both required runtime lanes pass the service's full gate with one property and
24 tests, no failures, at least 98% production line coverage. Strict analysis,
docs, audit, licenses and archive inspection are enabled. This is the storage
foundation of Phase 3; authentication, HTTP/OpenAPI/SSE, actual Runtime binding
peers, release/OCI and the non-Elixir client workflow remain to be implemented.

Integration inspection found Runtime at
`65d0b521ccb6b7838fe37bf26bf9dac65b40cc68` and HTTP binding at
`c150da67867933eb3fb040cc5049d11eb75d3f6a`, both with callable source APIs.
Those checkouts were inspected without modification. Passive BLE scanning still
has no upstream contract to consume; connected GATT discovery is not a scanner.

## WTR.07/08 authorization and privacy foundation — 2026-09-15

The service now has explicit hashed credential configuration, redacted scoped
access proofs, durable revocation checks, encrypted cursors and reviewed public
observation/resolution/measurement projections. The
[service contract](../contracts/service-v1.md) fixes the grant vocabulary,
credential limits, cursor binding and lossless browser scalar format.

Tests prove changed principal/scope/expiry/proof, credential replacement and
instance changes fail authorization; revoked credentials fail historical reads,
existing delivery checks, replayed mutations and a second writer after restart.
Ingestion cannot create enrollment, policy or revocation records. Cursor tests
cover tampering, wrong key/instance/principal/scope/purpose, expiry, future issue
time, malformed authenticated payloads and positions within a multi-event
generation. Public DTOs exclude raw receiver/hardware/protocol identity fields.
Zero/false/null, `1`/`1.0` and signed wide integer boundaries are distinct.

The guarded Store ports and prepared values are host primitives; a public
authenticated facade, HTTP/OpenAPI/SSE, access audit and production session
handling remain required. No listener or default credential is introduced by
this foundation. Physical Action authorization remains unimplemented.

Both required service runtime lanes passed the complete configured gate with
2 properties and 36 tests, zero failures and at least 98.4% production line
coverage. No tool or threshold was disabled. ExCheck 0.16.0 emits a development
startup warning when its umbrella probe reloads `../../mix.exs` under a temporary
project identity; this nested package is not an umbrella. The warnings-as-errors
compile and all verification commands still pass. This tooling warning is not
suppressed, and the isolated production consumers do not load ExCheck.

## WTR.07 authenticated domain facade — 2026-09-15

The service facade implements imported observations, public snapshots/inspection,
raw exports, resumable event reads, explicit enrollment, TD materialisation,
revocation and scoped operation-status lookup. Exact receipt replay precedes new
interpretation. Enrollment/materialisation read one immutable committed
generation and conditionally commit derived records, private lineage, generated
IDs and event intents together. Unknown inputs remain unknown; no automatic
hardware association or external publication is inferred.

Both required service runtime lanes pass the complete configured gate with
2 properties and 48 tests, zero failures and 97.9% production line coverage.
Cases include native browser/raw separation, snapshot/resume boundaries, changed
catalogue replay, request conflicts/expiry, explicit confirmation, unknown and
missing observations, limited enrollment authority, private lineage, validated
TDs, process restart and commit acknowledgement loss. The six isolated service
archive consumers also exercise authenticated import → enrollment → materialisation
and exact TD/receipt recovery after restart.

This completes the facade slice, not the full WTR.07 service gate. The reserved
property Forms are structurally validated against an explicit configured origin;
HTTP/OpenAPI/SSE transport, actual Runtime peers, CLI, bundled release/OCI and
the independent non-Elixir consumer remain outstanding. Rules, analytics and
hardware are separate later slices.

## WTR.07 bounded HTTP/OpenAPI/SSE foundation — 2026-09-15

An explicitly started per-instance Bandit/Plug server now exposes the imported
data workflow and durable event replay. The exact request/result/error and raw
export schemas are packaged as OpenAPI 3.1.0, contract 1.0.0. The independent
Python client reads that document over HTTP and validates actual exchanges.
It imports, inspects, enrolls, materialises, downloads raw bytes, resumes events,
revokes access and checks that an existing stream closes. Native `1`/`1.0`,
zero/false/null, byte payloads and wide integer projections are exercised across
the network boundary. Missing device/runtime/rule/analytics capabilities remain
explicit; no scanner or physical interaction is claimed.

The service gate has 2 properties and 60 tests with at least 96% production line
coverage on both required runtime lanes. Tests additionally cover verified TLS
using a fixture CA and server certificate, two independent instances, monitored
request/stream ceilings, hard expiry and deadline transfer, shutdown of an active
stream and all owned processes, media admission, malformed/duplicate/oversized
inputs, changed authorization before commit, self-revocation, unknown commit
acknowledgement, and redacted programming failures. No configured check or
threshold is disabled. The six isolated production archive consumers also run
the separate HTTP/SSE client against the installed package and retain no newly
owned processes after teardown.

This is software-peer listener evidence, not the full Phase 3 release gate.
Public history, Runtime ExposedThing/ConsumedThing binding interaction, CLI,
bundled release/OCI, signal/restart testing of that release and UI-enabled
composition remain outstanding. Header reads have a finite idle timeout and
byte/count/connection limits; the hard request deadline begins at Plug admission.
Production proxy/network policy and physical/hardware qualification remain
operator/platform work. Public sibling release availability is still unpassed.

## WTR.07 Runtime Property reads and actual HTTP peer — 2026-09-15

Committed TDs now drive upstream Runtime `ExposedThing` Property handlers. The
handlers read TD and state at one committed generation, enforce deadlines and
the packaged model's scalar type/unit/availability, and return native JSON.
Unavailable values return 503 without changing the TD. Runtime capability status
separates available reads from unsupported Property observation and Actions.

The explicit processless `HTTP.LoopbackClient` uses Mint 1.10.0 and the upstream
HTTP client port. It admits a configured numeric loopback origin and scope,
bounds header/status-line/body data and time, follows no redirects and retries
nothing. Credential custody remains caller-owned; only an opaque private-table
reference is retained in the tested `ConsumedThing`. Actual HTTP tests cover two
instances, temperature/pressure, unavailable state, revoked access, unsupported
Forms, response bounds, malformed framing, deadlines, caller death and socket
closure. The independent Python/OpenAPI client also reads actual TD Properties.

The service's complete gates pass on both required runtime lanes with 2 properties
and 65 tests and at least 95% production line coverage. No check or threshold is
disabled. The production artifact harness verifies immutable source snapshots of
Runtime `65d0b521ccb6b7838fe37bf26bf9dac65b40cc68` and HTTP binding
`c150da67867933eb3fb040cc5049d11eb75d3f6a`, including their configured checks,
warning-free documentation and boundary audits. Normal package requirements are
retained in the six clean signed-registry consumers; each performs the real
Runtime → HTTP binding → Mint → Tracker HTTP → ExposedThing read and independent
HTTP/SSE workflow, then checks that no owned processes remain. The sibling working
trees are unchanged. Archive identities are in `verification/service-consumer.json`.

This qualifies the finite read integration only. The HTTP binding supports SSE,
so the Phase 3 Property subscription acceptance remains required: a service
observation capability must be declared with host evidence, a value-specific
stream and scoped resume contract. Generic tracker events are not numeric
Property notifications. Public history, CLI, bundled release/image and its
signal/restart proof also remain outstanding. Public sibling release availability
is still unpassed; the local immutable artifact cohort is not a published release.

## WTR.07 public resource history — 2026-09-15

The service and OpenAPI now expose bounded public version history for the six
inspection resources. History preserves ascending committed versions and
deletion tombstones, with a sealed snapshot/ID/resource/page-size cursor and an
event high-water cursor from the same SQLite snapshot. Current authorization is
checked inside each read transaction; private evidence and observation payloads
remain behind raw export authority. The endpoint neither executes arbitrary
queries nor silently purges old records.

Both required service lanes pass all configured checks with 2 properties and
70 tests and at least 95% production line coverage. Tests cover writes between
pages, exact history-to-event handoff, restart/resume, wrong resource/ID/principal/
page-size/purpose, expiry, revocation, missing resources, malformed input,
retained tombstones and the 4 MiB response ceiling. The independent Python
client verifies history against served OpenAPI, including stable pagination
while new versions arrive, replay continuity and wide integer projections.
The six production archive consumers run that workflow against installed
artifacts, followed by real Runtime Property reads and complete teardown.

Property subscriptions, CLI, bundled release/image and its clean signal/restart
consumer remain outstanding Phase 3 work. Typed analytics queries and automatic
retention/deletion policy remain separately specified later work.

## WTR.07 standalone host startup and HTTP CLI — 2026-09-15

`hosts/app` now owns explicit service startup from a closed `wtr.host.v1` private
configuration file. It validates file type/permissions/links/ancestors, bounded
JSON, hashes, instance key, credential grants, numeric listen address and exposure
policy. The host has the application callback; the reusable packages remain
inert. Startup failures are bounded and do not expose configuration contents.

The POSIX Python 3.11+ standard-library CLI provisions a new private loopback
instance and performs the available machine workflows over HTTP. It separates
token custody from arguments/URLs, requires conditional generations, prints
operation identities before mutation attempts, distinguishes preflight failure
from uncertain network outcomes and never retries automatically. Finite request,
response, header, frame and stream budgets are enforced. Raw downloads preserve
the original response bytes in exclusive 0600 output files.

Both required host runtime lanes pass their complete configured checks with
5 ExUnit tests, 98.1% production Elixir line coverage and 5 additional Python CLI
tests. A separate process executes import/inspect/raw export/enrollment/
materialisation/Property reads/history/replay/SSE/revocation through the actual
host listener. Failure tests cover private-file admission, duplicate/oversized
input, disconnected mutation ambiguity, HTTP 202 receipts, proxy isolation,
redirect refusal, response/header/media/version limits, stream expiry and socket
closure. Host startup and shutdown own the listener and store lifecycle.

This is source-host evidence. Bundled ERTS release, OCI, clean artifact startup,
signal/restart/full-storage qualification and Runtime Property subscriptions
remain outstanding. No image or release is published, and no user instance is
configured by these tests.
