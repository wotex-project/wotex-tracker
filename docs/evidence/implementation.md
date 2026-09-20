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

`mix run --no-start scripts/qualify_source.exs` additionally passed six isolated production
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
export schemas are packaged as OpenAPI 3.1.0, contract 1.0.0. A separate BEAM
client reads that document over HTTP and validates actual exchanges.
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
closure. The separate OpenAPI client also reads actual TD Properties.

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
retained tombstones and the 4 MiB response ceiling. The separate BEAM client
verifies history against served OpenAPI, including stable pagination
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

The POSIX launcher and bundled Elixir CLI provision a new private loopback
instance and perform the available machine workflows over HTTP. They separate
token custody from arguments/URLs, requires conditional generations, prints
operation identities before mutation attempts, distinguishes preflight failure
from uncertain network outcomes and never retries automatically. Finite request,
response, header, frame and stream budgets are enforced. Raw downloads preserve
the original response bytes in exclusive 0600 output files.

Both required host runtime lanes pass their complete configured checks with
5 ExUnit tests, 98.1% production Elixir line coverage and 5 additional CLI
acceptance tests. A separate process executes import/inspect/raw export/enrollment/
materialisation/Property reads/history/replay/SSE/revocation through the actual
host listener. Failure tests cover private-file admission, duplicate/oversized
input, disconnected mutation ambiguity, HTTP 202 receipts, proxy isolation,
redirect refusal, response/header/media/version limits, stream expiry and socket
closure. Host startup and shutdown own the listener and store lifecycle.

This is source-host evidence. Bundled ERTS release, OCI, clean artifact startup,
signal/restart/full-storage qualification and Runtime Property subscriptions
remain outstanding. No image or release is published, and no user instance is
configured by these tests.

## WTR.07 bundled releases and local Linux image — 2026-09-15

The immutable production cohort now assembles the standalone host with bundled
ERTS for Darwin ARM64 and Linux ARM64. Both retain normal package requirements
and the source lock; a temporary signed loopback registry supplies unpublished
sibling artifacts. The Linux builder pins Elixir 1.18.4 / OTP 27.3.4.15 and Hex
2.5.1 on a digest-pinned Debian Bookworm base. A separate runtime image includes
only the libraries required by bundled ERTS, runs as UID/GID 10001, and contains
no external language tools or compiler. Release distribution is disabled. Runtime
license/notice files accompany the assembled release.

The separate BEAM/OpenAPI workflow runs against the actual bundled service.
It exercises enrollment, native Property reads, raw fidelity, immutable history,
snapshot/replay continuity, idempotency and revocation. The artifact lifecycle
probe closes an active SSE stream on SIGTERM, restarts from the same private
SQLite directory, confirms exact receipt replay and retained revoked access,
and verifies committed history after SIGKILL/restart. A real SQLite page ceiling
returns a definite storage-full rollback with no generation advance. Invalid
storage permissions fail startup; the Linux probe additionally runs with no
network, a read-only root filesystem and a private persistent volume, and rejects
an unwritable data destination. Logs are checked for fixture credential/key
leaks. Only fixture-owned containers and volumes are removed.

The two complete host verification lanes pass with 5 ExUnit tests, 98.3% Elixir
line coverage and 5 isolated CLI tests. The six clean production service consumers
also pass on the floor/current runtime lanes. Exact package, host source, archive,
base-image and built-image identities are recorded in
`verification/host-consumer.json`; artifacts remain under `_build/releases` and
the image remains local. Darwin was tested on the recorded development OS with
external BEAM tools removed from PATH; Linux provides the compiler-free runtime
qualification. Only Linux ARM64 is qualified here, not AMD64 or other platforms.

No image or release is published. Public sibling package availability, Runtime
Property subscriptions and the UI-enabled composition remain unpassed Phase 3
work. These software process-crash probes do not establish physical power-loss,
Pi/mobile or radio qualification. The exact artifact source hashes remain the
record of the executed build even as later implementation/documentation changes.

## WTR.04 explicit host Property delivery evidence — 2026-09-15

Pure materialisation accepts an optional pointer-to-transport-evidence declaration.
Before adding `observable: true`, it checks exact Forms/deployment identity,
complete read/observe/close operations, committed-value semantics and the same
readable capability parent/source lineage. A model explicitly disabling observation
is not overridden. Existing read-only TDs and default deployment digests remain
unchanged, and decoder capabilities still describe physical readable support.

Both root runtime lanes pass the complete gate with 1 doctest, 4 properties,
48 tests and at least 97.8% line coverage. Cases reject missing/altered/unsupported
witnesses and incomplete/mismatched streaming Forms. The host artifact cohort
also consumes this updated root archive. This establishes the pure declaration
contract; the service does not advertise observation until its stream and actual
Runtime client have passed their own checks.

## WTR.07 explicit later-observation association — 2026-09-15

The facade, HTTP contract 1.1.0 and CLI now support an explicit association of a
resolved admitted observation with an existing Thing. The mutation requires
current `enroll` authority, operator confirmation and a conditional generation.
It retains the Thing ID/title while recording fresh association/identity revision,
actor, observation and enrollment history. Materialisation is a separate atomic
mutation; importing or associating alone does not alter canonical state.

Both required service lanes pass the complete gate with 2 properties, 72 tests
and at least 96.1% line coverage. Both host lanes pass 5 ExUnit tests at 98.3%
coverage plus 5 isolated CLI tests. The separate CLI process verifies the real HTTP
flow from a 24.3 °C sample to a 30.0 °C sample, the unchanged Thing ID, retained
history and the deliberate state boundary between association and materialisation.
Tests reject missing confirmation, invalid/unknown/unresolved inputs, missing
authority, another scope and stale conditional writes. Receipt replay is exact.
The six clean production package consumers also execute reassociation and history;
their archive identities are recorded in `verification/service-consumer.json`.

The preceding bundled-host report remains the exact earlier artifact record;
this source/API addition does not rewrite that report or claim a new published
image. Automatic radio identity, physical-device authentication and autonomous
association remain outside this operator-confirmed software workflow.


## WTR.07 committed Property observation — 2026-09-15

Materialisation now adds observable Properties through the explicit host delivery
witness introduced in WTR.04. The new SSE endpoint dispatches upstream Runtime
observation against immutable TD/state generations. Initial snapshot/high-water
handoff, scoped encrypted resume and unavailable-sample gaps preserve the native
Property scalar and stable sample metadata. The HTTP/OpenAPI contract is 1.2.0;
`trackerctl observe` provides bounded delivery and explicit cursor resume.

The local HTTP binding client supplies monitored pending establishment and one
owned reader per subscription. Tests cover two simultaneous actual Runtime
subscriptions, independent close, owner/receiver loss, revocation, unavailable
samples, pending owner/caller death, handshake and stream deadlines, header/media
ambiguity, malformed/oversized SSE, queue pressure and secret-free reader state.
The SSE parser preserves UTF-8, BOM, CR/LF/CRLF and multiline fields across every
byte split of an independent fixture. It does not reconnect automatically.

Both service runtime lanes passed the complete gate: 2 properties and 87 tests,
0 failures, 95.5% / 95.6% production line coverage. Host gates passed on both lanes
with 5 ExUnit tests, 98.3% coverage and 6 independent CLI tests. The root's
unchanged pure code passed both complete gates with 1 doctest, 4 properties and
48 tests. No threshold, warning rule or dependency constraint was reduced.

Six fresh/locked/minimum production-archive consumers passed actual Runtime
reads and subscriptions with zero newly retained processes. Both bundled releases
passed the independent HTTP/OpenAPI/Property-SSE client and their packaged CLI's
snapshot/resume checks. Darwin ARM64 SIGTERM with an active stream took 1.023 s;
Linux ARM64 took 1.080 s. Restart/idempotency, SIGKILL recovery, retained revocation,
secret-free logs, license presence, unsafe storage and SQLite-full rollback passed.
The Linux runtime additionally passed read-only/non-root/no-network execution and
contains no external BEAM tools or compiler. Darwin has no external BEAM tools in
the probe PATH; its system compiler remains present, as previously recorded.

Exact archive, source, dependency, six-consumer and image identities for this
slice are recorded in `verification/host-consumer.json`. The separate source and
service reports retain their earlier snapshots. This evidence paragraph and plan
update were added after packaging. Nothing was
published. Sibling Runtime/HTTP revisions are unchanged; BLE still exposes no
passive scanner contract. The service's observation means committed host values,
not physical sensor notification qualification. UI composition, deterministic
rules, analytics and required physical delivery targets remain unpassed.


## WTR.05 position evidence and explicit freshness — 2026-09-16

The first pure tracking-policy slice admits closed normalized position claims
from validated evidence bundles. Receiver time must match a named source capture;
fix time, device time, source units, raw uncertainty, profile/decoder revisions,
confidence and association remain distinct. Zero coordinates, missing accuracy,
wide/negative times and native numeric identity are preserved. Private exports
retain provenance; no public location projection or physical positioning profile
is enabled by this slice.

Freshness uses an immutable content-bound policy and explicit Unix time. A trusted
fix takes precedence over reception; stale fixes cannot become fresh through late
delivery. Missing-time fallback, suspect quality and future-skew allowances require
explicit policy fields. Untrusted clocks, unavailable coordinates and inconsistent
time return reasoned unknown decisions. No clock is read, process started, canonical
position selected, rule state changed or physical Action dispatched.

Both required runtime lanes pass the complete root gate: 1 doctest, 5 properties
and 55 tests, no failures, 98.2% production line coverage. Independent reference
cases and generated replay cases cover threshold equality, clock jumps, delayed
receptions, altered provenance, missing/partial coordinates and all declared
admission shapes. Six fresh/locked/minimum production archive consumers exercise
position provenance and delayed-fix freshness with zero new processes; exact
artifact/lock identities are in `verification/source-consumer.json`.

The service/host reports retain the earlier Property-observation artifact snapshots.
Geometry, motion/trips/fences, rule persistence and physical position qualification
remain subsequent work. The pure root still requires only Wotex and OTP crypto at
runtime.

## WTR.05 deterministic multi-source position selection — 2026-09-16

The pure selector validates each complete position/evidence bundle and recomputes
freshness from the caller's explicit time and admitted freshness policy. Its
content-bound policy fixes accepted freshness order, source priority, unlisted
source handling, missing-accuracy handling and an optional stated-accuracy limit.
It returns either one fully ranked position or a reasoned unknown result; it does
not fuse coordinates or accept caller-supplied freshness labels.

The total order is freshness, declared source, valid/suspect quality, stated
accuracy, fix/reception time, evidence ID and bundle identity. Input permutations
and generated tie sets select identically. A delayed stale higher-priority source
cannot defeat a fresh lower-priority source. Duplicate evidence/bundle identities,
more than 64 candidates, forged position content and modified policy identities
fail explicitly. Unknown freshness, unavailable coordinates, missing accuracy,
unlisted sources and accuracy-limit rejection remain visible.

Both required runtime lanes passed the complete root gate with 1 doctest,
6 properties and 60 tests, no failures, 98.2% production line coverage. Six
fresh/locked/minimum production archive consumers re-evaluated the synthetic
position and selected it under an explicit stale-accepting policy, with no new
processes. Exact archive and lock identities are recorded in the updated
`verification/source-consumer.json`. This remains deterministic selection over
qualified evidence; geometry, motion state, trips and stateful policy are not
claimed by this slice.

## WTR.05 bounded geofence membership — 2026-09-16

The pure geofence value admits content-bound circles and simple polygons over
validated position evidence. Circle membership pins a WGS 84 authalic-radius
haversine calculation. Polygon membership pins a bounded local projection with
explicit antimeridian unwrapping. Boundary inclusion and coordinate-uncertainty
treatment are policy fields, and every result binds the fence identity to the
position evidence and bundle identities.

Admission rejects ambiguous 180-degree edges, duplicate and repeated closing
vertices, self-intersection, sub-square-metre areas, polar projection origins,
projected extents above 1,000 km and more than 64 vertices. Tests independently
check one-degree and antimeridian circle distances, boundary equality, uncertainty
bounds, wrapped polygons, unavailable positions, forged values and malformed
geometry. The implementation reads no clock and retains no process or rule state.

Both required runtime lanes passed the complete root gate with 1 doctest,
7 properties and 67 tests, no failures. Production line coverage was 97.0% on
Elixir 1.18.4 / OTP 27 and 97.1% on Elixir 1.20.4 / OTP 29. Six fresh, locked and
minimum production archive consumers exercised circle membership and the pinned
algorithm on both lanes with no new retained processes. Exact archive and lock
identities are recorded in `verification/source-consumer.json`.

The official WGS 84 defining parameters and the distinction between geodetic and
Earth-centred coordinates are recorded in the primary-source ledger. Tracker's
geometry remains its own documented bounded approximation; this evidence does not
claim ellipsoidal geodesic, survey or physical position accuracy. Initial state,
entry/exit transitions, sparse crossing inference, persistence and Actions remain
subsequent work.

## WTR.05 deterministic event and sequence ordering — 2026-09-16

`PositionSample` now binds a validated position to optional protocol-sequence
evidence in the same immutable bundle. The closed sequence claim identifies its
device/stream scope, reconnect session, modular value and exact receiver capture;
it must be a declared parent of the position evidence. Matching counter values
across different scopes or distinct reception provenance are not duplicates.

The content-bound `PositionOrder` policy fixes trusted event-time fallback,
future skew, a bounded late-arrival window and whether sequence evidence is
disabled, optional or required. Its total key resolves repeated timestamps with
receiver time and complete evidence identities. Modular comparison distinguishes
advance, wrap, ambiguous half range, older values, reconnect reset and independent
scope. Exact sample identity is the only duplicate result. Late samples request
ordered historical recomputation or history-only retention and never silently
rewind the accepted live head.

Both required runtime lanes passed the complete root gate with 1 doctest,
8 properties and 74 tests, no failures. Production line coverage was 96.9% on
Elixir 1.18.4 / OTP 27 and 97.0% on Elixir 1.20.4 / OTP 29. Cases include missing
and untrusted fix clocks, future receiver/fix time, repeated timestamp ties,
within/beyond-window arrivals, exact duplicates, counter conflict, wrap, reset,
scope change, modulus change and every generated modular increment below half
range.

Six fresh, locked and minimum production archive consumers execute the ordering
policy on both runtime lanes; their exact identities are recorded in
`verification/source-consumer.json`. This slice classifies order only. It does
not buffer late samples, mutate a rule head, emit an event, define an Action or
claim a protocol decoder supplied sequence evidence. Stateful rule event identity
and live/replay effects remain explicit work in the consuming state machine.

## WTR.05 ordered geofence transitions — 2026-09-16

The pure transition policy now combines admitted position ordering with bounded
geofence membership. Immutable state keeps the ordering head, last receiver
capture and last certain membership separate. Initial certain membership is a
baseline; uncertainty advances order without replacing the valid baseline; late
evidence may advance last-received status without rewinding canonical order.
Entry and exit require two certain endpoint memberships within the policy's
maximum time gap. A longer gap starts a new baseline.

Fence and rule changes recompute against an explicitly supplied current sample.
They emit a distinct `geofence.recomputed` event with the old/new fence, policy,
membership and evidence identities, rather than fabricating entry or exit. Event
IDs bind both endpoints and exclude processing mode and evaluation time. Live and
replay therefore produce identical state/event identities from the same ordered
history; replay marks physical Action dispatch prohibited, while live events still
require a separate authorized rule.

Both required runtime lanes passed the complete root gate with 1 doctest,
9 properties and 82 tests, no failures and 96.8% production line coverage. Tests
cover first membership, stable updates, entry/exit, uncertainty gaps, late
reception, exact transition-gap equality, exceeded gaps, fence/rule edits, modular
sequence conflict, invalid state/scope and generated live/replay equivalence.
Strict analysis, documentation, dependency, license and archive checks passed.

Six fresh, locked and minimum production archive consumers establish and
revalidate transition state on both runtime lanes. Their exact archive and lock
identities are recorded in `verification/source-consumer.json`. The pure result
is an atomic persistence input, not a persisted transaction: host storage/event
intent integration, sparse segment-crossing inference and any separately governed
Action rule remain subsequent work.

## WTR.05 bounded sparse-crossing inference — 2026-09-16

The pure geometry API now evaluates whether the straight centreline between two
certainly outside endpoint positions enters a circle or polygon interior. Circle
segments use an authalic azimuthal projection centred on the fence. Polygon
segments use the existing bounded antimeridian-aware local projection and split
the segment at edge intersections before testing interior intervals. Boundary
touches, inside endpoints and uncertain/unknown endpoints remain distinct from
an inferred crossing.

The content-bound crossing policy composes the complete event/sequence ordering
policy with maximum event-time and endpoint-distance gaps. Equality is accepted;
excess gaps return `not_inferred`. A crossing event retains both position/evidence
identities, both event times, both gaps and the geometry algorithm. It declares
straight-segment interpolation as the only route claim and leaves crossing time
`nil`. Live and replay produce the same event identity; replay prohibits physical
Action dispatch.

Both required runtime lanes passed the complete root gate with 1 doctest,
10 properties and 90 tests, no failures and 97.3% production line coverage.
Cases include circle/polygon interiors, exact circle tangency, a polygon edge,
antimeridian traversal, far misses, inside/uncertain/unavailable endpoints,
time/distance threshold equality and excess, out-of-order evidence, policy
mutation and generated direction symmetry. Strict analysis, docs, dependency,
license and archive checks passed.

Six fresh, locked and minimum production archive consumers infer a crossing and
inspect its no-crossing-time event on both runtime lanes. Exact identities are in
`verification/source-consumer.json`. This establishes bounded interpolation only;
it is not actual-route evidence, and host transaction integration remains separate.

## WTR.05 bounded two-fix movement evidence — 2026-09-16

The pure `PositionMovement` classifier combines two complete position samples
with the complete event/sequence ordering policy. Its content-bound policy fixes
moving and stationary distance/speed thresholds, a maximum plausible speed, a
maximum event-time gap and either guaranteed-bound or coordinate-only uncertainty
treatment. Stationary thresholds cannot exceed moving thresholds, so the
hysteresis region is explicit rather than silently assigned to either state.

Centreline distance uses the pinned WGS 84 authalic haversine calculation and is
periodic across the antimeridian. Guaranteed horizontal-accuracy radii expand
the possible distance into lower and upper bounds. Movement requires both lower
bounds to meet their thresholds; stationarity requires both upper bounds to meet
theirs. Missing guaranteed bounds, suspect/unavailable endpoints, repeated event
time, late ordering and excessive gaps return reasoned non-motion results. A
guaranteed lower speed above the declared physical limit is `implausible`.

Both required runtime lanes passed the complete root gate with 1 doctest,
11 properties and 98 tests, no failures and 97.4% production line coverage.
Cases include threshold equality, hysteresis, guaranteed versus estimated
accuracy, impossible speed, gap equality/excess, repeated timestamps, late
samples, forged policies, antimeridian symmetry and generated identical points.
Strict analysis, documentation, dependency, license and archive checks passed.

Six fresh, locked and minimum production archive consumers classify a synthetic
ordered segment on both runtime lanes. Exact archive and lock identities are in
`verification/source-consumer.json`. This evidence establishes a stateless
two-fix classification only. Dwell, trip/stop state, distance accumulation,
persistence and any physical Action remain subsequent work.

## WTR.05 dwell-based motion and trip transitions — 2026-09-16

The pure `MotionTransition` policy composes the complete bounded movement policy
with positive minimum movement and stop durations. Its immutable state keeps the
ordering head, last-received sample, usable segment baseline, pending dwell,
confirmed motion and active trip separate. The endpoint of a first classified
segment only starts a candidate; another consecutive segment of the same class
must confirm dwell, including at exact threshold equality.

Confirmed movement emits a content-identified `trip.started` event and active
trip. Confirmed stationarity emits `trip.stopped`; initial stationary dwell is a
baseline without an invented stop. Indeterminate evidence clears pending dwell
while retaining the last confirmed state. An excluded time gap, unavailable or
suspect evidence, impossible speed or rule revision interrupts an active trip and
resets motion to unknown. Rejected impossible positions cannot become a segment
baseline, while a valid post-gap endpoint can establish a new one.

Both required runtime lanes passed the complete root gate with 1 doctest,
12 properties and 107 tests, no failures and 96.7% production line coverage.
Cases include single spikes, class fluctuation, dwell equality, initial stationary
state, trip start/stop, gap and impossible-speed interruption, indeterminate
evidence, historical arrivals, rule revision, state mutation and generated
live/replay equivalence. Strict analysis, documentation, dependency, license and
archive checks passed.

Six fresh, locked and minimum production archive consumers establish movement
dwell and inspect the replay trip-start event on both runtime lanes. Exact archive
and lock identities are in `verification/source-consumer.json`. This slice does
not accumulate trip distance or persist state. Atomic state/event-intent storage
and any separately governed physical Action remain host responsibilities.

## WTR.05 bounded trip-distance reconstruction — 2026-09-16

`TripDistance` revalidates a content-identified active trip and a bounded sample
cohort against the complete motion policy. The cohort must begin at the trip's
candidate-onset sample, contain its confirmation sample, contain no duplicate
identities and already be in canonical order. The evaluator never silently sorts
or infers missing samples.

Every adjacent sample pair is reclassified. Only segments proved `moving` add to
the centre, lower and upper totals. Stationary, indeterminate, unknown and
implausible pairs remain explicit ledger entries with both evidence identities
and their exclusion reason. Later pairs still use their actual adjacent endpoint;
the algorithm never joins positions around an excluded pair. Accuracy bounds and
gap rules therefore remain visible in the reconstructed total.

Both required runtime lanes passed the complete root gate with 1 doctest,
13 properties and 112 tests, no failures and 96.6% production line coverage.
Cases include exact moving totals, separate accumulated uncertainty bounds,
stationary and over-gap exclusions, no bridging, duplicate/unordered/unscoped
cohorts, sample-limit exhaustion, policy/trip mutation and generated monotonically
ordered segment ledgers. Strict analysis, documentation, dependency, license and
archive checks passed.

The final source archive consumer reconstructs the identified synthetic trip on
both runtime lanes. Six fresh, locked and minimum consumer identities are recorded
in `verification/source-consumer.json`. The result is bounded reconstruction,
not persistent trip storage; host transaction integration remains separate.

## WTR.05 evidence-backed overdue heartbeat — 2026-09-16

The pure `HeartbeatTransition` policy derives current or overdue state from a
complete admitted receiver observation and explicit caller time. Its content
identity fixes maximum silence, permitted receiver future skew, threshold
equality and event semantics. A nil observation is an explicit time tick; no
clock, timer or process is hidden in the package.

Initial state is a baseline even if already overdue. Equality remains current and
the first following integer millisecond transitions to overdue at an exact derived
deadline. A newer current observation recovers overdue state. Observation order
uses receiver time, ID and full content identity; exact duplicates, historical
input and same-ID content conflicts remain distinct. Historical input can
accompany a deadline tick without replacing the canonical heartbeat. Caller-clock
regression and excessive future skew leave canonical state unchanged.

Rule changes emit `heartbeat.recomputed` rather than fabricating silence or
recovery. Overdue, recovered and recomputed event keys bind old/new policy and
observation identities and exclude live/replay mode. Replay produces identical
state and events while prohibiting physical Action dispatch.

Both required runtime lanes passed the complete root gate with 1 doctest,
14 properties and 119 tests, no failures and 96.7% production line coverage.
Cases include equality, repeated ticks, recovery, initially overdue/missing
evidence, future skew, clock regression, historical and conflicting observations,
rule revisions, state mutation and generated exact deadlines. Strict analysis,
documentation, dependency, license and archive checks passed.

The final six fresh, locked and minimum archive consumers execute a replay
deadline transition on both runtime lanes and record exact identities in
`verification/source-consumer.json`. Host monotonic scheduling and atomic state/
event-intent persistence remain separate work.

## WTR.05 evidence-backed low-battery state — 2026-09-16

`MeasurementSample` now revalidates a measurement evidence record and its closed
bundle, reconstructs the exact native `Measurement` claim and selects the latest
named receiver observation by a deterministic total order. Its identity binds the
evidence, bundle, receiver capture and receiver time. The generic measurement map
import is closed and rejects unknown enum strings or fields.

The pure `BatteryTransition` policy names the exact measurement kind and unit,
distinct low and clear thresholds, maximum age, future skew and suspect-quality
treatment. Equality is included at each threshold. The band between thresholds
retains established normal/low state and is unknown without a baseline.
Unavailable, stale, excessive-future and rejected suspect measurements remain
reasoned unknown results. Voltage is never converted into battery percentage.

Initial evaluation establishes a baseline. A transition to low emits
`battery.low`; low-to-normal emits `battery.recovered`. Aging a low sample to stale
changes state to unknown without inventing recovery. Historical and duplicate
samples cannot replace the canonical sample, same-ID changed evidence conflicts,
and rule edits emit `battery.recomputed`. Live/replay state and event identities
match; replay prohibits physical Action dispatch.

Both required runtime lanes passed the complete root gate with 1 doctest,
15 properties and 127 tests, no failures and 96.7% production line coverage.
Cases include both threshold equalities, hysteresis, initial low/unknown baselines,
availability, quality, freshness/future skew, clock regression, history,
duplicates/conflicts, rule revision, multi-source receiver ordering, claim/state
mutation and generated numeric classifications. Strict analysis, documentation,
dependency, license and archive checks passed.

The final six archive consumers select the Ruuvi voltage evidence and evaluate an
explicit voltage policy on both supported runtime lanes; exact identities are in
`verification/source-consumer.json`. Hardware-specific thresholds, persistent
state/event intent and any physical notification remain deployment concerns.

## WTR.05 three-valued suspicious movement — 2026-09-16

`PolicyFact` introduces a closed true/false/unknown claim bound to exact or strong
retained evidence, its full bundle, derivation-policy revision, reason and latest
named receiver observation. It does not derive false from missing evidence or
radio silence. Candidate-confidence evidence and malformed/extended claims fail
closed.

The pure `SuspiciousMovement` policy binds a complete motion policy, exact armed
and owner-presence predicates, fact freshness/future skew and an explicit choice
for interpreting unknown owner presence. Three-valued conjunction clears when
any condition is false, triggers only when every condition is true, and otherwise
returns unknown. By default, missing or stale owner presence remains unknown.
Only a policy that expressly elects `owner_unknown_as_absent` can reinterpret it.
Armed unknown always remains unknown.

A true result emits a stable `suspicious_movement` event binding the active trip,
motion state, armed fact, owner fact and rule identity. Live and replay produce
the same event; replay prohibits physical Action dispatch. Re-evaluation returns
the same idempotency key for atomic host deduplication.

Both required runtime lanes passed the complete root gate with 1 doctest,
16 properties and 133 tests, no failures and 96.7% production line coverage.
Cases include all explicit false conditions, retained versus explicitly converted
unknown presence, unknown/stale/future armed facts, closed fact claims,
multi-source observation order, predicate and nested-policy mismatch, mutation,
live/replay identity and generated freshness equality. Strict analysis,
documentation, dependency, license and archive checks passed.

The final six archive consumers build explicit armed and owner-absence evidence
and evaluate the rule against a confirmed replay trip on both runtime lanes.
Exact identities are in `verification/source-consumer.json`. Enrollment authority,
fact production, atomic event intent and notifications remain host responsibilities.

## WTR.06 evidence-qualified transport selection — 2026-09-16

`TransportCandidate` now binds separate bearer and application-protocol names to
exact capability and connectivity facts, cost and power classes, supported
acknowledgement layers and a stable content identity. Capability evidence uses
the closed `transport.<candidate>.capable` predicate and connectivity evidence
uses `transport.<candidate>.available`; neither a profile name nor receipt of a
radio frame is silently promoted to availability.

The pure `TransportPolicy` declares deployment-specific ordinary and critical
route order, fact-policy revision and freshness, policy budget ceilings, exact
acknowledgement requirements and the no-route outcome. Request-specific cost and
power budgets apply in addition to policy ceilings. Every candidate is reported
in a deterministic ledger, including missing, unlisted, stale, unknown,
over-budget, unconfirmed and wrong-revision routes. Input enumeration cannot
change selection.

Acknowledgement observations name the delivery, candidate, layer and state.
Pending and unknown outcomes hold without retry. An acknowledgement from a
different layer cannot satisfy the policy, while a definite failure can exclude
that route and admit the next qualified fallback. The decision does not claim a
remote application or physical Action effect.

Both required runtime lanes passed the complete root gate with 1 doctest,
17 properties and 140 tests, no failures and 96.6% production line coverage.
Cases cover independent bearer/protocol values, ordinary store-and-retry,
critical cellular fallback, fact truth/revision/freshness, dual budget ceilings,
acknowledgement support and outcomes, content mutation, list bounds, duplicate
IDs and generated candidate-order invariance. Strict analysis, documentation,
dependency, license and archive checks passed.

The six final archive consumers select the cellular fallback from an unavailable
LoRaWAN route on both supported runtime lanes; exact archive and lock identities
are in `verification/source-consumer.json`. The policy remains pure. Durable
queueing, policy-state persistence, Continuum snapshot conversion and actual
radio/network delivery remain host integration work.

## WTR.06 bounded durable store-and-forward — 2026-09-16

The service store now admits closed `ForwardItem` values into SQLite schema 2.
Each item binds scope and item ID, selected candidate, bearer, application
protocol, native JSON payload, source reliability, admission time and exact
required acknowledgement layer. A transactional schema-1 migration adds only
the queue table and due index; tests retain and read a pre-migration scope.

The queue fixes per-scope count and encoded-byte ceilings, maximum age and retry
attempts. Age and attempt limits are captured in each row at admission so restart
with different configuration cannot extend existing work. Claims serialize
across independent SQLite writers, order by admission time then ID, and commit
attempt plus next-retry time before returning bytes. Expiry and attempt exhaustion
produce durable discarded receipts. Terminal receipt cleanup is explicit and
cannot remove pending items.

Reliable overflow returns `queue_full` without a commit. Lossy overflow records
a durable `overflow` receipt while receipt capacity remains. Completion requires
a prior claim, exact content identity and either send completion for a no-ACK
route or acknowledgement at the exact policy layer. Earlier timestamps and
different layers fail closed. Identical completion is idempotent; conflicting
completion is rejected. Unknown after-commit admission is resolved by the same
durable item status.

Both service runtime lanes passed the complete gate with 2 properties and 96
tests, no failures and at least 95.5% production line coverage. Cases cover
item/byte limits, reliable versus lossy
overflow, FIFO/retry/restart, exact expiry and exhaustion, cross-writer claims,
layered completion, explicit cleanup, schema migration, malformed input and
pre/post-commit failure. Compiler, formatter, strict Credo, Dialyzer, ExDoc,
dependency audit, licenses, OpenAPI validation and archive inspection passed.

The six production service consumers admit a queue item from the installed
archive, restart SQLite, claim it and record durable-server-admission completion
before exercising the existing authenticated HTTP and Runtime lanes. Exact
archive and lock identities are in `verification/service-consumer.json`. No
radio sender, external server, automatic retry process or Continuum conversion
is claimed; the host adapter still owns those effects.

## WTR.05 transport degradation state — 2026-09-16

`TransportPolicy.validate_decision/3` now revalidates the closed decision schema,
policy binding, bounded route ledger, exact outcome shape and content identity.
A changed reason, selected route, policy identity, outcome or extra field cannot
be replayed as the original decision.

The pure `TransportDegradation` rule embeds the exact transport policy and an
explicit deployment set of candidate IDs that count as healthy. A fresh selected
or acknowledged candidate in that set is healthy. A selected fallback,
store-and-retry result or unavailable result is degraded. Pending and unknown
acknowledgements, stale decisions and excessive-future decisions remain unknown;
freshness and future-skew equality are inclusive.

The first decision establishes a baseline. Changes emit stable
`transport.degraded`, `transport.recovered` or rule-edit
`transport.recomputed` events. Duplicate and historical decisions cannot replace
newer canonical state. Live and replay evaluation produce identical state and
event identities; replay prohibits physical Action dispatch and live events still
require separate authorization.

Both required runtime lanes passed the complete root gate with 1 doctest,
18 properties and 147 tests, no failures and 96.1% production line coverage.
Cases cover declared healthy candidates, fallback and no-route degradation,
recovery, pending and exact acknowledgements, age/future equality, duplicates,
history, clock regression, policy recomputation, decision/state mutation and
generated candidate-order invariance. Compiler, formatter, strict Credo,
Dialyzer, ExDoc, dependency audit, licences, documentation contracts and archive
inspection passed.

The final six archive consumers establish healthy cellular state and then a
replay degradation event from a no-route decision on both supported runtime
lanes. Exact archive and lock identities are in
`verification/source-consumer.json`. Atomic policy-state/event persistence,
Continuum conversion, notifications and actual transport effects remain host
integration work.

## WTR.06 atomic transport-health persistence — 2026-09-16

Transport policy and degradation policy/state values now have closed native-JSON
serialization that reconstructs through their public constructors and verifies
every content identity. `RuleTransition` accepts only a changed pure transition,
re-evaluates its state, event and effect, and binds the expected prior-state
identity before it reaches storage.

SQLite schema 3 adds one canonical state row per scoped rule and a deduplicated
stable event-intent table. A single `BEGIN IMMEDIATE` commit compares the expected
state identity, advances scope generation, appends immutable state history and,
when present, records both event intent and public domain event. Exact retries
return the committed generation. Stale writers and reused event identities with
changed content fail without a partial write. Pre-commit failure rolls back;
after-commit uncertainty is resolved by the same transition identity after
restart. Schema 1 upgrades through schema 2, and direct schema-2 upgrades retain
existing scopes and queue support.

Both required root runtime lanes passed the complete gate with 1 doctest,
18 properties and 147 tests, no failures and 95.7% production line coverage.
Both service runtime lanes passed with 2 properties and 103 tests, no failures
and 95.3% floor / 95.5% current production line coverage. Cases cover state and
policy round trips, changed documents and events, competing writers, exact retry,
stale expectation, stable event deduplication, live/replay action metadata,
restart recovery, both migration paths, storage capacity and failures on both
sides of commit. Compiler, formatter, strict Credo, Dialyzer, ExDoc, dependency
audit, licences, OpenAPI validation, documentation contracts and archive
inspection passed.

The production service consumer commits a healthy baseline from installed
archives, restarts SQLite, restores the state through the pure constructor, then
atomically commits a replay degradation event and proves exact retry and
prohibited physical dispatch. Exact archive and lock identities are recorded in
`verification/service-consumer.json`. Evaluation scheduling, notification
delivery, public rule management and equivalent persistence for other rule types
remain separate work.

## WTR.05/06 atomic heartbeat persistence — 2026-09-16

Heartbeat policies and state now have closed native-JSON forms that restore the
complete admitted receiver observation and recheck the derived status, deadline
and every content identity. Stable overdue, recovery and recomputation events
have a closed validator that recomputes their idempotency key. Transition
admission re-evaluates the pure result before it reaches host storage.

The schema-3 rule transaction now admits `heartbeat` alongside
`transport_degradation`. It compares the expected prior state identity, advances
canonical state and immutable state history, and records any stable event intent
plus public domain event in one SQLite commit. Restart recovery reconstructs the
pure state. Exact retry returns the committed generation, stale or changed
transitions conflict, and replay intent permanently records prohibited physical
dispatch. This uses the existing generic tables and requires no migration.

Both required root runtime lanes passed the complete gate with 1 doctest,
18 properties and 147 tests, no failures and 95.6% production line coverage.
Both service runtime lanes passed with 2 properties and 105 tests, no failures
and 95.5% floor / 95.6% current production line coverage. Cases cover policy and
state round trips, changed nested observations, deadline/status/identity
mutation, event mutation, stable-result rejection, restart restoration, overdue
intent commit, exact retry and replay effect metadata. Compiler, formatter,
strict Credo, Dialyzer, ExDoc, dependency audit, licences, OpenAPI validation,
documentation contracts and archive inspection passed.

The production service consumer commits an installed-archive heartbeat baseline,
restarts SQLite, reconstructs the state, evaluates the exact overdue deadline in
replay, and proves atomic event intent plus retry deduplication. Exact archive
and lock identities are recorded in `verification/service-consumer.json`. The
host still needs a monotonic deadline scheduler and notification delivery.

## WTR.05/06 atomic low-battery persistence — 2026-09-16

Evidence, complete evidence bundles and measurement samples now have closed
native-JSON forms that restore through their public constructors without creating
atoms. Battery policies and state also restore from closed documents while
rechecking measurement kind and unit, hysteresis status, observation/evidence
closure and every content identity. Stable low, recovery and recomputation events
have a closed validator that recomputes their idempotency key, and transition
admission re-evaluates the pure result before storage.

The schema-3 generic rule transaction now admits `battery` alongside heartbeat
and transport degradation. It atomically compares the expected prior identity,
advances canonical state and immutable history, and records any stable event
intent plus public domain event. Restart recovery reconstructs the complete
sample closure. Exact retry returns the committed generation, stale or changed
transitions conflict, and replay intent permanently records prohibited physical
dispatch. The existing generic tables require no migration.

Both required root runtime lanes passed the complete gate with 1 doctest,
18 properties and 147 tests, no failures and 95.0% production line coverage.
Both service runtime lanes passed with 2 properties and 107 tests, no failures
and 95.5% floor / 95.6% current production line coverage. Cases cover closed
evidence/bundle/sample serialization, policy and state round trips, changed
nested content, status/identity/event mutation, restart restoration, low-battery
intent commit, exact retry, stale-writer rejection, snapshots and replay effect
metadata. Compiler, formatter, strict Credo, Dialyzer, ExDoc, dependency audit,
licences, OpenAPI validation, documentation contracts and archive inspection
passed.

The production service consumer commits an installed-archive normal-battery
baseline, restarts SQLite, reconstructs its complete sample, evaluates an exact
low threshold in replay, and proves atomic event intent plus retry deduplication.
Exact archive and lock identities are recorded in
`verification/service-consumer.json`. Measurement ingestion, age scheduling and
notification delivery remain host work.

## WTR.05/06 atomic motion and trip persistence — 2026-09-16

Ordering, movement and dwell policies now have closed native-JSON forms that
restore nested policy identities without atom creation. Complete position samples
restore through their evidence bundles. Durable motion state stores a sorted,
deduplicated registry containing only samples still referenced by the canonical
head, last reception, segment baseline, pending dwell or active trip. Restoration
reconstructs every reference and rejects duplicates, unused samples, dangling
identities and changed nested content.

Motion transition admission re-evaluates changed results and validates stable
trip event identities before storage. The schema-3 generic transaction now admits
`motion`, compares the expected prior state identity, and atomically advances
canonical state, immutable history and any trip-start, stop or interruption
intent. Pending dwell and active-trip state survive restart. Exact retry returns
the committed generation, stale or changed transitions conflict, and replay
intent retains prohibited physical dispatch. The generic tables require no
migration.

Both required root runtime lanes passed the complete gate with 1 doctest,
18 properties and 148 tests, no failures and 95.1% production line coverage.
Both service runtime lanes passed with 2 properties and 109 tests, no failures
and 95.6% floor / 95.7% current production line coverage. Cases cover nested
policy/sample/state round trips, malformed registries and references, policy enum
rejection, live/replay transition validation, restart restoration of pending
dwell, trip-start intent commit, exact retry and stable-result rejection.
Compiler, formatter, strict Credo, Dialyzer, ExDoc, dependency audit, licences,
OpenAPI validation, documentation contracts and archive inspection passed.

The production service consumer commits an installed-archive baseline and
pending movement dwell, restarts SQLite, reconstructs the exact state, confirms
the trip in replay, and proves atomic `trip.started` intent plus retry
deduplication. Exact archive and lock identities are recorded in
`verification/service-consumer.json`. Position ingestion, trip-summary
materialization and notification delivery remain host work.

## WTR.05/06 atomic geofence persistence — 2026-09-16

Fences, geofence-transition policies and canonical geofence state now have
closed native-JSON forms that restore through public constructors without atom
creation. Durable state stores the complete fence and ordering policy plus a
sorted, deduplicated registry containing only the position samples referenced by
the ordering head, last reception and last certain membership. Restoration
rejects duplicate or unused documents, dangling identities and changed nested
evidence.

Changed transition admission re-evaluates the pure result at its explicit
evaluation time and validates stable entry, exit and recomputation event
identities. The schema-3 generic transaction now admits `geofence`, compares the
expected prior identity and atomically advances canonical state, immutable
history and any stable event intent. Exact retry returns the committed
generation, changed results conflict, and replay intent retains prohibited
physical dispatch. The existing generic tables require no migration.

Both required root runtime lanes passed the complete gate with 1 doctest,
18 properties and 150 tests, no failures and 95.0% floor / 95.1% current
production line coverage. Both service runtime lanes passed with 2 properties
and 111 tests, no failures and 95.6% floor / 95.7% current production line
coverage. Cases cover circle and polygon fence restoration, nested policy and
state round trips, malformed registries and references, live/replay transition
validation, restart restoration, entry intent commit, exact retry and
stable-result rejection. Compiler, formatter, strict Credo, Dialyzer, ExDoc,
dependency audit, licences, OpenAPI validation, documentation contracts and
archive inspection passed.

The production service consumer commits an installed-archive outside baseline,
restarts SQLite, reconstructs its complete state, evaluates an entry in replay,
and proves atomic `geofence.entered` intent plus retry deduplication. Exact
archive and lock identities are recorded in `verification/service-consumer.json`.
Position ingestion, notification delivery and public rule management remain host
work.

## WTR.16 deterministic measurement analytics — 2026-09-16

The first pure analytics core now admits closed content-identified query rows,
absolute UTC query specifications and snapshot-bound results. Queries select one
numeric measurement/unit and up to eight explicit series, qualify valid or
suspect rows, and request count, minimum, maximum, mean or stable last-observed
values in bounded buckets. Windows are from-inclusive/to-exclusive, limited to
31 days and 1,000 points per series. The evaluator accepts at most 100,000 rows,
rejects duplicate identities and incompatible units, preserves native integer or
float values where the aggregation permits, and orders equal last-observed times
by row identity.

Unavailable and rejected-quality rows are disclosed separately. Empty buckets
remain absent so consumers can preserve gaps. Result admission binds the exact
query, committed snapshot identity, series order, bucket geometry, sample totals,
last-row references and disclosure counts under the existing 256 KiB
materialization budget. Closed codecs reject unknown fields, vocabulary changes,
forged identities, duplicate buckets and inconsistent counts. The pure library
starts no process and reads no clock or store.

Both required root runtime lanes passed the complete gate with 1 doctest,
19 properties and 158 tests, no failures and 95.4% production line coverage.
Both service runtime lanes passed with 2 properties and 117 tests, no failures
and 95.9% floor / 96.0% current production line coverage after rebuilding the
changed root dependency and Dialyzer PLTs. Compiler, formatter, strict Credo,
Dialyzer, ExDoc, dependency
audit, licences, documentation contracts, OpenAPI validation and archive
inspection passed.

Six root and six service production-archive consumers execute the admitted query
and result codecs plus a known-answer aggregation on both runtime lanes in fresh,
locked and minimum dependency modes, while retaining zero new Tracker processes.
Exact archive and lock identities are recorded in
`verification/source-consumer.json` and `verification/service-consumer.json`.
Query pagination, operational telemetry, named display timezones, saved
dashboards, prompting and dynamic graphs remain required host and product work.

### Service-backed structured queries — 2026-09-16

The service now accepts the closed query document through `Service.analytics/5`
and the read-only `POST …/analytics/query` operation in OpenAPI contract 1.5.0.
It rechecks scope-level `read` authority inside one SQLite read transaction,
pins the current scope generation and extracts matching numeric measurements
from committed state history. The adapter retains native zero/integer/float
semantics, rejects duplicate requested measurements and malformed stored scalar
or quality metadata, and binds a deterministic service snapshot identity into
the core result. The endpoint has no mutation receipt or idempotency key.

The separate HTTP client constructs the content identity independently from
the service domain modules, validates the query and result against JSON Schema, executes a
known-answer query and verifies that forged input fails without mutation
metadata. Restart tests prove an identical committed snapshot result; scope
isolation, unavailable rows, quality exclusion, unit conflicts and storage
failure paths are covered.

Both required root runtime lanes passed the complete gate with 1 doctest,
19 properties and 158 tests, no failures and 95.4% production line coverage.
Both service runtime lanes passed with 2 properties and 123 tests, no failures
and 95.7% floor / 95.8% current production line coverage. Compiler, formatter,
strict Credo, Dialyzer, ExDoc, dependency audit, licences, documentation
contracts, generated/packaged OpenAPI equality and archive inspection passed.

The production service archive consumer executes the installed facade query;
its independent HTTP client validates and executes the same public operation.
The root archive consumer continues to exercise the pure known-answer query on
both runtime lanes in fresh, locked and minimum dependency modes. Exact archive
and lock identities are recorded in `verification/source-consumer.json` and
`verification/service-consumer.json`.

### Cancellable bounded query execution — 2026-09-16

Structured analytics now runs on dedicated read-only SQLite connections rather
than in the serialized writer. Admission permits eight concurrent queries,
two per principal and sixteen starts per principal in each one-second window.
Every accepted connection retains the existing in-transaction authorization and
generation snapshot. Opening a query never creates or migrates storage.

A watchdog monitors the caller, store and deadline. Any one ending repeatedly
cancels the Exqlite busy/progress handlers until the query worker exits, and the
worker owns release of both global and principal reservations. Tests exercise
both a real 100,000-row JSON history scan canceled at a ten-millisecond store
deadline, a caller killed before its connection opens and store shutdown after
a connection opens. The writer remains writable after cancellation, abandoned
replies cannot reach a later call, and admission boundaries reject explicitly
as overloaded.

Both service runtime lanes passed the complete gate with 2 properties and
127 tests, no failures and 95.2% floor / 95.3% current production line coverage.
Compiler, formatter, strict Credo, Dialyzer, ExDoc, dependency audit, licences,
generated/packaged OpenAPI 1.6.0 equality and archive inspection passed. The
root implementation and its 158-test gate remain unchanged by this service-only
execution slice.

### Transactional saved query definitions — 2026-09-16

The service now persists `wtr.saved-query.v1` definitions containing one
previously admitted absolute-window query and closed line, area, points or table
visualization options. Save, update and delete use the existing UUID operation
identity, scope-generation compare-and-swap and atomic record/event/receipt
transaction. Each version retains a private principal owner, projects only a
scope pseudonym and emits `query.changed`; deletion retains an explicit history
tombstone. A different administrator cannot replace or delete an owned
definition.

Current read authority remains the data boundary. Reading or copying a saved
definition grants nothing, and `Service.execute_saved_query/5` plus the matching
HTTP GET validate the stored document and pass it through the same snapshot,
concurrency, refresh-rate, timeout and cancellation path as a direct structured
query. No model call is involved. This revision deliberately stores fixed
absolute incident windows; rolling resolution and dashboard sharing policy
remain future contracts.

Both service runtime lanes passed the complete gate with 2 properties and 131
tests, no failures and 95.1% floor / 95.2% current production line coverage.
Compiler, formatter, strict Credo, Dialyzer, ExDoc, dependency audit, licences,
generated/packaged OpenAPI 1.7.0 equality and 59-member archive inspection
passed. Tests cover create/update/replay/delete, immutable history, owner
isolation, invalid definitions, stale generations, deterministic execution and
the public HTTP lifecycle.

The separate BEAM client validates the new request, resource, result,
receipt, event and tombstone shapes against the packaged JSON Schema before
exercising them. The production service archive consumer saves, replays, reads,
executes and histories a definition through the installed facade. The remaining
analytics work is query pagination, rolling windows, named display timezones,
operational telemetry, prompt translation and interactive graph/dashboard UI.

### Bounded local operational history — 2026-09-16

The service now emits closed `request.stop` and `query.stop` telemetry with
integer microsecond durations, query row counts and bounded operation, outcome
and aggregation categories. The vocabulary excludes scope, principal, record,
position, prompt and payload values. Loading the package attaches no handler and
starts no process.

An explicitly supervised `OperationalHistory` owner attaches only those events
and stores valid samples in protected ETS. It retains at most 2,048 samples for
15 minutes by default, admits only finite configured bounds, exposes coherent
snapshots under a unique collector epoch and clears history on restart. The
default explicit HTTP host owns one collector and exposes it only to host code;
no metrics server or exporter is required. Invalid external telemetry and a
failed host clock are ignored or reported unavailable without affecting durable
tracking or alarm decisions.

Both service runtime lanes passed the complete gate with 2 properties and 135
tests, no failures and 95.1% floor / 95.2% current production line coverage.
Compiler, formatter, strict Credo, Dialyzer, ExDoc, dependency audit, licences,
generated/packaged OpenAPI 1.7.0 equality and 61-member archive inspection
passed. Tests cover the exact vocabulary, capacity and expiry boundaries,
malformed events, filtered snapshots, restart epochs and real HTTP request
capture. Ingestion, decoding, admission, queue, publication, reconnect and
native-resource events remain required instrumentation work.

### Operational pipeline outcomes — 2026-09-16

The closed vocabulary now also emits `ingest.stop` for document admission and
protocol decode, `store.stop` for ordinary and rule transactions, `queue.stop`
for enqueue/claim/complete/cleanup, `publication.stop` for durable intent reads
and reconciliation, and `resource.stop` for readiness, checkpoints and backups.
Every event uses low-cardinality atoms and elapsed microseconds. Queue events
also report coherent post-operation pending item/byte depth, processed items and
lossy overflow drops without exposing a scope or item identity.

Instrumentation observes the existing result and cannot change it. The default
collector handler only sends a message to its supervised owner; malformed
external measurements are rejected by the same closed sample admission. Tests
exercise real import and SQLite commit paths, a reliable queued item, a lossy
overflow, missing publication lookup and writable-store readiness, then inspect
the retained event documents for exact outcomes and absent identifiers.

Both service runtime lanes passed the complete gate with 2 properties and 137
tests, no failures and 95.2% floor / 95.3% current production line coverage.
Compiler, formatter, strict Credo, Dialyzer, ExDoc, dependency audit, licences,
generated/packaged OpenAPI 1.7.0 equality and 61-member archive inspection
passed. Reconnect, render and native host-resource events remain with the future
adapters and UI that own those operations.

### Snapshot-pinned analytics pagination — 2026-09-16

The service now exposes `Service.analytics_page/5` and the read-only
`POST …/analytics/pages` operation in OpenAPI contract 1.8.0. A first request
partitions one admitted absolute query into a bounded bucket window and pins the
current committed scope generation. Its encrypted seven-day continuation binds
the exact query identity, page size, next index, principal, scope and service
instance to that generation. Every continuation rechecks current read authority;
later commits remain excluded without keeping a SQLite transaction open between
requests. Ascending and descending pages cover disjoint bucket windows in global
query order.

Tests insert a write between pages and prove that all continued results retain
the first generation and snapshot while a fresh query sees the new row. They
also cover descending traversal, final partial pages, exact request admission,
future and malformed cursors, changed queries and page sizes, principal binding
and revocation before resume. The separate BEAM HTTP client validates and
traverses the public page schemas against the served OpenAPI document. The
production service archive consumer traverses the same two-page continuation
through the installed facade.

Both service runtime lanes passed the complete gate with 2 properties and 142
tests, no failures and 95.1% production line coverage. Both required root
runtime lanes remained green with 1 doctest, 19 properties and 158 tests, no
failures and 95.4% coverage. Compiler, formatter, strict Credo, Dialyzer, ExDoc,
dependency audit, licences, documentation contracts, generated/packaged OpenAPI
equality and 62-member service / 93-member root archive inspection passed.

Six root and six service production-archive modes pass in fresh, locked and
minimum dependency configurations across both runtime lanes. Exact archive and
lock identities are recorded in `verification/source-consumer.json` and
`verification/service-consumer.json`. Rolling windows, named display timezones,
prompt translation and interactive graph/dashboard UI remain required analytics
work.

### Restart-safe rule deadlines — 2026-09-16

The service now rebuilds bounded heartbeat and battery deadlines from canonical
SQLite rule state. It converts each persisted receiver-time deadline once into a
local monotonic deadline, replaces timers when their state identity changes and
rejects stale timer tokens. A restart immediately re-evaluates elapsed deadlines;
wall-clock movement after scheduling cannot delay or advance the local timer.
The default explicit HTTP host supervises this scheduler beside its store.

Heartbeat expiry, battery freshness expiry and future-skew eligibility reuse the
existing pure live transition contracts. Each resulting state and stable event
intent commits atomically before another deadline is loaded. Battery freshness
expiry does not invent an alert, and scheduling never sends a notification or
dispatches a physical Action. Capacity is limited to 1,024 persisted rules, the
refresh interval is bounded and corrupt stored rule documents fail closed.

Tests cover elapsed-deadline recovery after restart, wall-clock regression,
battery staleness, future-skew reconsideration, changed-state timer replacement,
early and stale timer messages, unavailable and unresponsive store supervisors,
capacity, corrupt storage and store-owner loss. Both service runtime lanes passed
the complete gate with 2 properties and 152 tests, no failures and 95.1% floor /
95.2% current production line coverage. Both root runtime lanes remained green
with 1 doctest, 19 properties and 158 tests, no failures and 95.4% coverage.
Compiler, formatter, strict Credo, Dialyzer, ExDoc, dependency audit, licences,
documentation contracts, generated/packaged OpenAPI equality and 63-member
service / 93-member root archive inspection passed.

Six root and six service production-archive modes pass in fresh, locked and
minimum dependency configurations across both runtime lanes. The service
consumer persists a heartbeat, restarts the store, runs the explicit scheduler
and observes the committed overdue transition. Exact archive and lock identities
are recorded in `verification/source-consumer.json` and
`verification/service-consumer.json`. Geofence and suspicious-movement scheduling
and notification delivery remain subsequent host work.

### Transport decision deadline scheduling — 2026-09-16

The persisted rule scheduler now restores transport-health state alongside
heartbeat and battery state. An excessive-future decision is reconsidered at its
exact permitted-skew boundary. Every decision that is not yet stale, including a
pending or unknown outcome, is reconsidered at the first millisecond beyond its
declared maximum age. A stale tick persists unknown health and does not fabricate
a degradation or recovery event.

Tests prove first-stale-millisecond behavior after both the store and scheduler
restart, exact future-skew eligibility, the subsequent stale deadline and absence
of a public event for healthy-to-unknown expiry. Both service runtime lanes passed
the complete gate with 2 properties and 154 tests, no failures and 95.2%
production line coverage. Both root runtime lanes remained green with 1 doctest,
19 properties and 158 tests, no failures and 95.4% coverage. Compiler, formatter,
strict Credo, Dialyzer, ExDoc, dependency audit, licences, documentation contracts,
generated/packaged OpenAPI equality and 63-member service / 93-member root archive
inspection passed.

Six root and six service production-archive modes pass in fresh, locked and
minimum dependency configurations across both runtime lanes. The service consumer
also observes a persisted healthy transport decision become unknown through the
installed scheduler. Exact archive and lock identities are recorded in
`verification/source-consumer.json` and `verification/service-consumer.json`.
Input-triggered rule orchestration and notification delivery remain subsequent
host work.

### Rolling saved query windows — 2026-09-16

Saved query requests can now add the exact rolling-window object with a positive
duration matching the admitted absolute query template. The service persists
these definitions as `wtr.saved-query.v2` while retaining the existing
`wtr.saved-query.v1` representation and execution behavior for requests without
window metadata. Each authorized rolling execution replaces the template bounds
with a fresh from-inclusive/to-exclusive interval ending one millisecond after
the supplied host time, re-admits the resulting query and exposes its exact
bounds and content identity in the result.

Tests prove that a current-millisecond sample is included, a later execution
moves the interval and excludes the old sample, malformed or inconsistent window
metadata fails before storage, and legacy definitions remain unchanged. Current
read authority, committed snapshot selection, query concurrency, rate limits,
deadline cancellation and ownership rules continue to apply independently on
every execution. A live HTTP test validates a rolling save, resource and result
against OpenAPI contract 1.9.0. The installed service archive consumer exercises
the same versioned definition through the public facade.

Both service runtime lanes passed the complete gate with 2 properties and 155
tests, no failures and 95.0% floor / 95.1% current production line coverage.
Compiler, formatter, strict Credo, Dialyzer, ExDoc, dependency audit, licences,
the OpenAPI structure/reference audit and 63-member service archive inspection
passed. The separate BEAM HTTP/SSE process validates live exchanges against the
served schemas and retains the prior negative protocol coverage.

Six root and six service production-archive consumers have since passed in fresh,
locked and minimum modes on both required runtime lanes with the migrated Elixir
orchestrator. The exact revised archive and lock identities are recorded in
`verification/service-consumer.json` and `verification/host-consumer.json`.
Named display timezones, dashboard composition and sharing, prompt translation,
interactive graphs, input-triggered rule orchestration and notification delivery
remain subsequent work.

### Stack-native artifact qualification — 2026-09-16

The signed local registry, six archive consumer modes, static registry server,
independent HTTP/OpenAPI client, bundled release lifecycle probe and host CLI now
run on Elixir/OTP. The CLI's POSIX launcher uses bundled ERTS and the release's
clean boot script. The Linux builder and runtime image install no Python package.
The runtime keeps only its bundled BEAM and required system libraries.

Both Darwin and Linux ARM64 releases passed actual HTTP/SSE and packaged CLI
Property snapshot/resume, active-stream SIGTERM shutdown, restart and receipt
replay, SIGKILL recovery, retained revocation, private-storage rejection and a
definite SQLite-full rollback. Linux additionally passed a non-root, read-only,
network-isolated runtime probe and an unwritable data destination. Its image
contains no external BEAM toolchain or compiler. Root, service and host complete
local gates pass at 95.4%, 95.0% and 98.3% production line coverage respectively.
Exact source, archive, dependency, image and result identities are recorded in
`verification/host-consumer.json`. No release or image was published.

The separate-process BEAM HTTP consumer imports no service domain code and checks
actual wire exchanges against the served OpenAPI schemas. The sibling repository
language findings and migration targets are recorded in the
[stack language audit](../provenance/stack-language-audit.md).

### Independent Rust HTTP/SSE consumer — 2026-09-16

A Rust client now starts from a private descriptor and uses only raw loopback
HTTP, SSE and JSON. It imports no Tracker modules. It checks the served OpenAPI
version and public route, rejection of an unsupported API version, unauthorized
and reader-denied requests, idempotent observation admission, conflict rejection
for a reused key with a different body, and receipt lookup. It preserves native
integer/float/zero/false/null raw values and checks enrollment, materialisation,
a Property read, Thing history and a known-answer structured analytics query
with a separately computed content identity. It checks forged-identity rejection,
two snapshot-pinned analytics bucket pages, an altered-cursor rejection and
continuation after an unrelated commit. It saves,
executes and tombstones a query through public endpoints, checks its history,
and verifies a reader cannot save it. It resumes retained events and holds an
already-ready SSE connection open while the reader is revoked, verifying that
the server closes it and denies the old page cursor.

The clean artifact harness compiles this client for Darwin ARM64 with a local
Rust toolchain and for Linux ARM64 in a digest-pinned Rust 1.97.1 slim builder.
The locked Cargo manifest and source stay outside the release. Both final bundled
releases passed the native client in addition to the BEAM/OpenAPI consumer; the
Linux binary ran in the read-only, non-root, network-isolated runtime container
without installing Rust or a compiler there. The exact native binary hashes,
compiler versions, release source hashes and lifecycle results are in
`verification/host-consumer.json`.

This establishes the implemented non-Elixir workflow slice. Complete product
acceptance still requires policy operations and authorized
interactions across this boundary when their owning features are available, plus
the UI, mobile, Pi and physical gates. No image or release was published.

### Host-owned BEAM resource samples — 2026-09-16

The explicit HTTP server supervises a sampler after its bounded operational
collector. It reports total BEAM-managed bytes, process count and port count
on startup and every 30 seconds through one closed `runtime.sample` event.
The collector applies its existing capacity, retention and restart epoch. These
are VM-wide values, not process RSS, per-instance or per-tenant measurements.
An explicit host test reads the resulting sample and checks its exact units,
positive values and bounded metadata. Killing the sampler restarts only that
child; the store PID and collector epoch remain stable. Loading the service
package remains inert. Each production-archive service consumer also checks a
retained resource sample from its explicitly started HTTP host.
Reconnect, rendering and OS-native resource instrumentation remain open work.

### Browser render telemetry — 2026-09-16

The optional browser host now attaches to Phoenix LiveView render spans and
records root Tracker view duration and completion outcome in the existing
bounded volatile collector. The handler is explicitly supervised with the
browser, ignores other views and component spans, and forwards only a fixed
surface/outcome pair. It never forwards socket, asset, route or exception data.
Headless artifacts do not install this handler. Service and browser-host tests
cover the closed event contract, sample retention and metadata exclusion.
Reconnect and OS-native resource events remain open.

### Pinned operational history pages — 2026-09-16

The collector now exposes a host-only bounded page read. A continuation carries
the exact filter, page size, collector epoch, last sequence and first-page
high-water sequence. Concurrent new samples stay outside the traversal. Tests
exercise multiple pages, an intervening sample, altered filters and limits,
collector restart, and retention expiry. The production service archive
consumer traverses its real HTTP request history through this interface.
Operational pages are volatile and do not turn into durable asset history.

### Shared browser enrollment and asset inspection — 2026-09-16

`packages/tracker_ui/` now contains the first shared LiveView workflow: sign-in,
bounded observations and assets, retained profile evidence, explicit ownership
confirmation, enrollment, Thing provisioning, actual scalar measurements with
quality and UTC time, and bounded immutable state history. The package has no
application callback or endpoint and imports no host. Its local client calls
only the public authorized service facade and resolves the current service on
every request. Session stores are explicit, independently named host resources.

Enrollment and provisioning establish a UUID operation reference in the page
URL before permitting submission. Reconnect reads the durable receipt and checks
that it belongs to the expected resource/workflow. The test adapter can execute
a real service mutation and discard its reply: both enrollment and provisioning
then show an unknown outcome, recover the committed receipt and create no
duplicate resource. Stale generation, unrelated receipts, read-only mutation
attempts, failed refresh and missing resources have explicit outcomes.

The bounded, volatile session owner retains the bearer only in server memory.
Its monotonic expiry is independent of wall-clock authorization, and separate
stores cannot reuse each other's session IDs. Tests check capacity, expiry,
invalid/duplicate configuration, redacted process status, logout and durable
service revocation. The HTTP cookie is encrypted, HttpOnly and SameSite=Strict;
Secure follows the declared public HTTPS origin. CSRF validation, no-store/CSP
headers and non-reflection are exercised. A test verifies and decodes the actual
signed LiveView payload and checks that it contains only the opaque browser
session and framework CSRF state, with no bearer credential. Mounted views
reauthorize before events and at a five-second idle interval.

The optional `WOTEX_TRACKER_UI=1` app-host composition owns PubSub, sessions and
the Phoenix/Bandit endpoint. Its separate private browser configuration declares
the listener, public origin and secret. The headless build has separate dependency
and build state and rejects browser configuration when its artifact lacks UI.
Actual HTTP tests exercise sign-in without bypassing CSRF, observation browsing,
all local assets, foreign WebSocket-origin rejection and Secure cookies behind
an explicitly declared HTTPS proxy. Listener, parser and WebSocket frame bounds
are explicit. No external asset service or build-time scripting runtime is used.

Desktop Chrome review executed sign-in, fixture enrollment, provisioning,
measurements and sign-out. A 390 × 844 viewport review checked the same layout
and keyboard access to the horizontally scrolling history table. These are
software browser observations, not physical mobile or complete accessibility
acceptance. The review used a disposable local service and synthetic fixture;
its listener and browser tab were stopped after verification.

The complete local gates pass on Darwin ARM64 with both Elixir 1.18.4 / OTP
27.3.4.15 and Elixir 1.20.4 / OTP 29.0.4. The shared UI runs 17 tests at 98.6%
production line coverage; the headless host runs 12 at 97.8%, and the UI-enabled
host runs 14 at 98.0–98.1%. All pass with no test failures. Their gates include
warnings-as-errors compilation, formatting, strict Credo, Dialyzer, ExDoc,
dependency audit, licenses and the stack-language check. The UI archive is
inspected with ordinary dependency metadata and excludes tests and host code.
The root gate also passes on the floor runtime at 95.4% production coverage.

Complete setup/import, maps/trips, protection, interactions, privacy controls,
analytics screens and remote-service presentation remain open. The existing
headless artifact receipts retain their original scope and source identities.
Pi, mobile and all physical gates remain unpassed.

### Bundled browser artifact qualification — 2026-09-16

The local signed registry packages the shared UI with ordinary production
dependency metadata. Six isolated consumers install its archive in fresh,
locked and minimum modes on Elixir 1.18.4 / OTP 27.3.4.15 and Elixir 1.20.4 /
OTP 29.0.4. Each executes the public session and presenter contract from the
installed package, confirms its local assets and absent host/application
callback, then verifies invalid credentials and logout denial. No consumer
imports repository source or starts the app host.

Separate Darwin ARM64 and Linux ARM64 bundled ERTS hosts resolve the local
signed registry and include the optional UI. Their release probe signs in over
HTTP with real CSRF/cookie handling, inspects an enrolled asset and its retained
measurements, fetches all four local JavaScript/CSS assets, then proves a browser
cookie from before restart no longer grants access. The same release lifecycle
also passes HTTP/OpenAPI/SSE, CLI Property resume, receipt replay, active-stream
SIGTERM, SIGKILL recovery, durable revocation and definite SQLite-full rollback.
An independent Rust client passes its enrolled-asset, analytics, paging and
stream-revocation flow on both artifacts. Linux runs the probe as a non-root user
inside a read-only, network-isolated image and tests an unwritable data
destination. Its runtime image has no external BEAM tools or compiler.

The archive, dependency lock, host source, runtime base, native client and
per-platform results are recorded in `verification/ui-consumer.json`.
The bundles and image are local artifacts; none was published. These probes
qualify the first browser workflow and release composition, not a complete
tracking application, physical device, Pi panel or mobile companion.

### Browser capture import and later association — 2026-09-16

The shared Setup screen now accepts one operator-selected Observation JSON file
of at most 256 KiB. It decodes through the bounded service JSON codec and calls
the authorized `submit` facade; it does not create or scan a capture. The import
operation reference is in the URL before upload is offered. A committed receipt
is checked against the retained observation and its commit generation. Unknown
outcomes suppress another submission until the operator checks the receipt.
Tests execute real service mutations through the LiveView upload channel, then
exercise reconnect, lost replies, malformed and oversized files, stale writes,
read-only denial, unrelated receipts and temporary read failure.

An existing asset now offers a bounded observation picker and a separate
evidence-and-confirmation screen. The authorized `associate` facade returns the
Thing ID, selected public observation ID and newly recorded association ID in
the atomic receipt. These exact fields allow the browser to recover a lost reply
without mistaking enrollment or materialisation for this association. A changed
source observation leaves prior measurements visible and explicitly marked as
prior until the operator updates the Thing; service state remains canonical.
Tests exercise association, a later materialisation with changed RAWv2 values,
receipt recovery, stale and read-only denial, pagination and unrelated operation
references. The app-host HTTP test and both bundled browser probes reach the
selector and confirmation form through ordinary artifacts.

This is a software setup path for admitted captures. Live BLE scanning, physical
identity proof, a qualified mobile/Pi interface and the remaining application
workflows are still unpassed. Updated local package/release receipts are in
`verification/ui-consumer.json` and `verification/host-consumer.json`; neither
artifact was published.

### Structured browser measurement queries — 2026-09-16

The shared browser now offers a per-asset query screen over the public authorized
`Service.analytics/5` facade. It selects a numeric measurement and its recorded
unit from the current retained state, accepts explicit UTC bounds and finite
bucket/aggregation options, then constructs the closed `QuerySpec` before service
execution. A reader credential may query but cannot mutate the asset. The result
shows the pinned snapshot, qualified and excluded row counts, only observed
buckets, sample counts and event times. It explicitly says that absent buckets
are gaps and does not present this historical view as a live connection.

The LiveView cohort checks a known value, an empty later interval, injected
measurement rejection and revocation; the host HTTP and bundled browser probes
check the actual query form through the composed route. Live graphs, gestures,
saved-dashboard controls, provider translation and hardware UI acceptance remain.

### Gap-preserving browser graphs — 2026-09-16

The browser now projects the same authorized result into line, area and point
SVG views. A pure Elixir geometry adapter scales even constant and large values
without inventing zero and splits paths whenever adjacent returned buckets do
not touch. Every point has a title with its value, sample count and bucket time;
the exact accessible table remains below the graph. Buttons shift and zoom the
absolute UTC window, then submit a newly validated service query. Changing a
visualization does not add a second data authority.

The pure chart tests assert separate paths across an unobserved interval, exact
zero preservation, empty output and constant extreme values. LiveView tests
exercise all three views and time-window controls. Host HTTP tests and packaged
Darwin/Linux browser probes check the graph selector in the actual application.
This is historical exploration; scheduled refresh, direct pointer gestures,
saved dashboards, model translation and physical surface acceptance remain open.

### Saved-query browser inspection — 2026-09-16

The shared browser now lists saved query definitions in bounded service pages
and opens a definition under the user's current read grant. Running it calls
`Service.execute_saved_query/5`, which reauthorizes and selects a new committed
snapshot. The view displays the stored window policy and visualization type,
uses the same graph and exact table for one series, and shows every series in
separate tables when a saved definition contains several. Empty series remain
visible. No browser state or shared link expands the service grant.

LiveView tests exercise a rolling definition under a reader credential, an
absolute multi-series table, absent definitions, a temporary query failure and
mid-session revocation. The composed-host HTTP test checks saved listing and
detail through its authenticated listener; bundled browser probes reach the
listing. Browser save/edit/delete controls, dashboard composition and sharing,
scheduled live refresh and physical surfaces remain unqualified.

### Browser dashboard save and recovery — 2026-09-16

The per-asset analytics screen now lets an administrator save the displayed
closed query as a fixed or rolling definition. It captures the current scope
generation, puts a fresh operation UUID in the URL before showing the save form,
and submits only the admitted query, title, window policy and closed graph
options through `Service.save_query/6`. The committed receipt identifies the
saved definition; the browser checks its asset series before reporting success.
Reader credentials cannot prepare or submit a save.

LiveView tests cover a rolling save and reconnect, a fixed save, invalid input,
stale-generation refusal, a lost reply, a failed verification read, a temporary
transport failure, read-only denial and an unrelated operation reference. An
unknown outcome hides the form and can be checked through the retained receipt
without sending the mutation again. Dashboard composition/sharing, scheduled
live refresh and physical surface acceptance remain open.

### Browser dashboard edit and deletion — 2026-09-16

The saved dashboard screen now prepares title/view edits and deletions with a
current scope generation and an operation UUID in its address. The edit keeps
the admitted query and fixed or rolling window intact; the service checks the
owning administrator. Both mutations carry action-specific receipts, so a
revisit after a lost reply can distinguish the committed edit from a deletion
without repeating the write. An unknown result hides the controls; stale
generations fail without overwriting a newer definition. Browser tests cover
reconnect recovery, reader denial, stale writes and unrelated receipts.
Dashboard composition/sharing, subscription-driven refresh and physical surface
acceptance remain open.

### Bounded saved-dashboard refresh — 2026-09-16

An open saved dashboard can now opt into a 30-second timer. Each tick reloads
its definition and executes through the current authorized service facade. A
temporary lookup or execution failure keeps the last successful result with a
visible stale label and retries; deletion or lost read authority clears the
result and stops the timer. Manual runs, definition refreshes and navigation
stop it, and an epoch rejects queued ticks from a prior run. LiveView tests
cover failure and recovery, changed definitions, deletion, revocation and a
late tick after stopping. Subscription-driven updates and physical UI
acceptance remain open.

The reader's displayed graph or table now follows an externally edited saved
view on the next successful automatic refresh. If the reader explicitly
switches views on the open page, that temporary choice survives refresh and a
stale-result retry. A manual run or definition refresh restores the saved
default. LiveView tests cover both paths.

### Browser query-result export — 2026-09-16

Both the per-asset analytics screen and saved dashboard now offer a JSON export
of their current service-returned `QueryResult`. The export does not rerun the
query: its content identity and snapshot are the ones shown on the page. The
closed document retains query bounds, units, qualified values, exclusion counts,
downsampling disclosure and gap policy. The browser creates a local file from
the LiveView event; no export path accepts a client-supplied result. Workflow
tests re-admit exported documents, verify representative values, reject export
without a result and deny it after session revocation.

### Saved-series comparison — 2026-09-16

The shared browser now lets an administrator select two to eight compatible
saved definitions and persist their distinct series as one multi-series query
with an exact-table visualization. Selection is limited to the current bounded
page; measurement, unit, query settings and window policy must agree. A scope
generation check prevents a concurrent definition change from being ignored.
The page retains a stable operation reference and verifies a committed receipt
against the new saved definition. Workflow tests cover normal execution, a lost
reply, failed verification read, stale generation, incompatible or duplicate
series, reader denial and unrelated operation references. General composition,
sharing and physical surface acceptance remain open.

### Shared-scale saved graphs — 2026-09-16

Saved multi-series definitions can now render line, area and point views on a
shared value scale. Each trace keeps separate paths across missing buckets;
empty series have no invented mark and remain explicit in the table. Series
labels and exact tables make the graph readable without relying on color alone.
Unit tests check common scaling, zero, gaps and an empty series. A LiveView test
executes a two-series saved definition with one qualified series, checks the
graph and tables, then edits the view to area and reruns it. Physical Pi/mobile
and browser gesture acceptance remain open.

### Browser reading-quality filters — 2026-09-16

The per-asset structured query now offers valid, suspect, or both admitted
qualities. The closed `QuerySpec` carries the choice through service execution,
JSON export and saved definitions; invalid readings are never selectable. A
LiveView test checks exclusion counts for suspect-only against a known valid
reading, inclusion for both, persistence after save and rejection of an
unrecognized client selection.

### Browser Property reads — 2026-09-16

The asset page now lists only Properties declared by its public Thing Description.
A reader can request one through the current authorized service facade, which
uses Runtime's read-only Property dispatch against committed state. The page
shows the returned value and generation and says that it did not contact the
physical device. Unknown names are rejected before the service call. A failed
read clears the previous value and can be retried; a LiveView test covers reader
authority, successful temperature/pressure reads, tampering and temporary
unavailability. Write/Action controls remain contingent on qualified affordances.

### Temporary saved-result views — 2026-09-16

After running a saved query, a reader can switch its current result among table,
line, area and points views. The projection uses the same returned `QueryResult`
and does not rerun the service query or edit the saved definition. The selected
control exposes its state through `aria-pressed`. A LiveView test switches each
view, checks that the result identity remains visible, rejects an unrecognized
view and confirms that the stored visualization is unchanged.

### Asset overview summaries — 2026-09-16

The browser overview now reads the current authorized state for each asset on
its bounded enrollment page and shows retained observation time, typed
measurement values, units, availability and quality. It distinguishes an asset
without committed state from a temporary state-read failure and warns when the
readings came from an earlier associated observation. The cards say that device
connectivity is unknown; their separately fetched values are not presented as
one shared snapshot. A denied read clears the whole page instead of retaining
older card contents. LiveView tests cover provisioning, refresh, failed reads,
denial and reader access. Position, map, protection and physical surface
workflows remain open.

A terminal list-refresh denial also clears the visible cards and their retained
summaries. Temporary list failures keep the prior page with an error for retry.
The browser workflow test covers the denial and recovery path.

Asset details, observation evidence, reassociation and the observation picker
also clear retained projections after a terminal read denial or a missing
record. A later authorized refresh restores the page. Temporary storage
failures retain the prior evidence for retry; a workflow test exercises these
boundaries across the shared LiveView screens.

### Authorized history-page export — 2026-09-16

The asset page can download its current bounded state-history page as JSON. A
fresh service history request must return the same generation, rows and
continuation state before the socket emits the export. A changed snapshot
invalidates the displayed page; denied access clears asset detail; temporary
failure retains the page for retry. The exported public projection includes
commit order and a `has_more` indicator but omits session-bound history and
event cursors. The LiveView test checks exact rows, conflict, failure and denial.
Route replay, full-range export and mobile sharing remain open.

### Reauthorized query downloads — 2026-09-16

Structured analytics and saved-dashboard JSON downloads now rerun the displayed
absolute query under current service read authority and require the same result
identity before emitting the existing file event. The saved dashboard first
checks that its definition is still accessible and unchanged. A changed
snapshot or terminal denial clears the displayed result; a temporary service
failure keeps it visible with an error for retry. Workflow tests cover exact
downloads, changed snapshots, transient failure and denied reads.

### Revisiting history pages — 2026-09-16

The asset detail now keeps a bounded stack of 32 previously visited state-history
page requests. Forward and backward navigation each fetch the page again under
current read authority; a temporary failure retains the displayed page and its
navigation state, while a terminal denial clears both. Refresh begins a new
history snapshot at the first page. A browser workflow test exercises a real
26-version store history across the page boundary, failure and denial. If a
fresh earlier page belongs to a newer snapshot, the displayed page remains in
place with a conflict until refresh starts a new history traversal.

### Returning through browser lists — 2026-09-16

The shared asset, setup, association-picker and saved-dashboard lists now keep
at most 32 prior page requests.
Each return fetches fresh authorized rows and requires the original list
generation; a changed snapshot leaves the current page visible with a conflict.
Transient list failures preserve navigation, while terminal denial clears the
rows and back path. A successful refresh starts a new first-page traversal.
The browser tests cover 26 committed observations and saved dashboards, both
directions, later commits, transient failures and denial.

### Exploring saved dashboard windows — 2026-09-16

The saved-dashboard detail now shifts and zooms its displayed result using the
same bounded UTC window calculation as structured analytics. Each adjustment
runs a fresh authorized absolute query, keeps the stored definition unchanged
and marks the page as an exploration. A saved run restores the configured
window. Temporary query failure retains the last result; terminal denial clears
it. The browser test checks the returned bounds, snapshot, export, reset,
failure and denial.

### Optional prompted graph path — 2026-09-16

The analytics page accepts a natural-language question only when its host
installs a prompt adapter. It gives that adapter the question, permitted
measurement names/units, closed choices and UTC time, but no asset identifier,
retained value or service credential. A clarification does not run a query.
Closed proposed fields are checked against the currently displayed measurement
schema and reconstructed as `QuerySpec`; the authorized service still decides
access and returns all graph points. Provider absence, malformed output and
transport failure leave structured analytics usable. Synthetic workflow tests
cover disclosure, clarification, invented fields and service denial.

The browser host has an optional OpenAI Responses adapter behind a private
configuration. It uses strict JSON-schema output, `store: false`, no tools, a
bounded HTTPS response, no retry, an absolute deadline and cancellation of
abandoned requests. The host checks explicit rate, concurrency, byte, token and
operator-supplied price budgets. Unit tests exercise the request shape, response
parser, bounded pool and synthetic transport failures. No live paid-provider run
has been recorded; product acceptance of the public path remains open.

### Authorized browser operational history — 2026-09-16

The optional browser host exposes `/operations` to current administrators. Its
host adapter checks admin authority before and after each bounded collector
read. The shared view filters closed event names, shows no more than 25 retained
samples per page, and navigates with the collector epoch and first-page
high-water mark. A transient read failure keeps the prior page with an error;
revocation, expired cursors and malformed pages clear it. The route is disabled
for generic UI consumers and absent from headless host artifacts. UI workflow
and real loopback-browser tests cover paging, filter, failure, denial and
non-disclosure of credentials. Time-windowed operational graphing remains open.

### Discrete operational sample plot — 2026-09-16

The browser operational page can plot one closed telemetry measurement from
its current 25-sample page. Its scatter marks follow collector record order
and are never joined or spaced as an elapsed-time series. The exact table and
UTC timestamps remain visible. The selected measurement is checked against
the documented event contracts; missing values yield an explicit empty plot.
Pure projection and LiveView tests cover sparse, constant, absent and switched
measurements. A larger time-windowed operational view remains open.

### Bounded complete retained-history export — 2026-09-16

The asset page can now download all retained state versions when they fit ten
100-row service pages and a 1 MB JSON envelope. Each page is fetched through
the authorized service; its continuation pins the first committed generation.
The browser emits a file only after the entire traversal succeeds. Changed
generation, revoked access, expired or repeated cursor, malformed page and
budget excess produce no partial file. The export contains exact public rows
and the snapshot generation, but no service cursors. Pure collector tests cover
multi-page success and failure; a LiveView workflow exercises a real 26-version
history, a failed read and the browser download event. Larger histories still
need a separate bounded streaming or paged workflow.

### Grant-gated raw evidence downloads — 2026-09-16

The observation review page offers native capture and full claim JSON downloads
only when the current credential holds `raw` authority. A click uses the
authorized service facade again; bytes go directly to the browser download
event and are never kept in LiveView assigns or ordinary HTML. Reader-only
credentials do not see the controls and the service denies a forged download
request. The workflow test checks both exact service documents, denial on a
later click and non-disclosure in rendered markup. Broader data deletion and
access-management workflows remain open.

### Current browser access inspection — 2026-09-16

The shared browser has an authenticated `/access` view of the current principal,
scope, credential expiry and read/import/enroll/raw/admin grant categories. It
uses the authorized service facade to refresh the credential summary and the
existing reauthorization hook for current permission flags. It displays no
bearer or raw credential ID and explains that sign-out ends only the browser
session. Workflow tests cover admin and read-only views, transient failure,
denial and non-disclosure; the real loopback host serves the route. A historical
access audit and revocation management remain open.

### Private rule history storage — 2026-09-17

Persisted rule transitions previously appended their history under the public
asset `state` record kind. A reader listing `state` therefore saw rule record
IDs with `null` values, and reading or paging that ID returned an empty public
projection. Store schema 4 now keeps rule versions under a private `rules`
record kind that no public resource reads. The transactional 3-to-4 migration
moves only records whose ID matches a canonical rule state in the same scope;
asset state and other scopes remain unchanged. Readiness reports schema `4`
under HTTP contract revision 1.10.0, and snapshot analytics require that schema.
Store tests upgrade a version-3 database with mixed rule and asset history, and
a service test confirms that public `state` list, get and history no longer
disclose committed heartbeat history.

### Read-only public rule status — 2026-09-17

The service facade and HTTP contract 1.11.0 now expose a `rules` resource for
committed heartbeat, battery, transport-health, motion and geofence state. List,
get and history reuse the snapshot-bound page and history cursors and require
current `read` authority. Every stored document is restored through its pure
state constructor before a closed `wtr.rule-status.v1` projection is returned;
a damaged or mismatched document returns `storage_unavailable`. The projection
contains rule and state identities, status, times, thresholds, active trip
summary and fence identity, but no receiver observation, evidence bundle,
sample, coordinate, distance or transport ledger. Capabilities report rules as
`read_only`; configuration, arming, evaluation and alert acknowledgement remain
unsupported.

Service tests commit all five rule kinds, check exact heartbeat and battery
projections, page across a later commit, return both heartbeat versions, reject
foreign cursors and identifiers, reauthorize after revocation and fail closed on
damaged latest or historical versions. Baseline motion and bounded-geofence
tests cover a missing trip and missing valid membership. A separate BEAM HTTP
consumer validates capabilities, paged list, get, history, 400/401/404 outcomes
and response bytes against OpenAPI while a supervised rule scheduler runs.

### Paged saved-query history — 2026-09-17

Saved-query history continuations were rejected by the encrypted history cursor
allowlist. A history page with more versions than its `limit` therefore raised
while issuing the next cursor, which HTTP reported as an internal error. The
cursor now admits `saved_queries`; the saved-query lifecycle test pages its two
edits and deletion tombstone with a continuation.

### Browser rule status — 2026-09-17

The shared browser adds a Protection navigation entry. `/protection` pages the
service `rules` projection with the same bounded 32-page return path as other
lists, and `/protection/{kind}:{rule_id}` shows one rule's current committed
status, thresholds and timing with paged evaluation history. Each card and
detail explains that status is a committed deterministic evaluation, not live
device connectivity, and that these pages cannot change, arm or acknowledge a
rule. Status text is always shown; no color carries meaning.

LiveView tests commit all five rule kinds and check their statuses, battery
reading, fence revision, route decision and trip start while refuting capture
IDs, hardware identifiers, coordinates and evidence bundles. They page 26 rules
with a transient failure, a changed generation and a terminal denial, and page
27 heartbeat versions with transient history and state failures, denial and a
missing rule. The optional app host serves `/protection` through its real
loopback listener without disclosing the bearer. Rule configuration, alert
acknowledgement, maps and physical-surface acceptance remain open.

### Command-line rule status — 2026-09-17

`trackerctl` now accepts `rules` for `list`, `inspect` and `history`, using the
same bounded HTTP client, output and exit contract as other public resources.
The independent CLI consumer checks against the provisioned host that
capabilities report rules as `read_only`, an empty scope returns an empty rule
page at generation 0, and missing rule inspection and history return
`not_found`. The CLI cannot create or evaluate rules.

### Versioned rule definitions — 2026-09-17

HTTP contract 1.12.0 adds administrator-managed `policies`. A heartbeat or
battery definition binds a lower-case rule ID to one existing Thing with an
exact closed parameter set. The service assigns the revision from the commit
generation, builds the pure policy, stores its content identity and keeps the
acting principal private. Battery rules must name a declared numeric Property
in the same unit, so an unsupported measurement is rejected instead of silently
remaining unknown. Kind and Thing are immutable for an ID, one Thing admits at
most eight definitions, and deletion retains a tombstone. Saves and deletions
publish `policy.changed` through the ordinary receipt and event contract.

Service tests cover exact projections, revision identities, replay, edits that
preserve creation time, listing, paged history with the tombstone and events.
They reject reader writes, malformed IDs and parameters, missing Things,
unsupported battery measurements, stale snapshots, kind and Thing changes, a
ninth definition and invalid deletion, while still allowing edits at the limit.
The independent HTTP consumer validates save, 401/409/501 outcomes, get, list,
delete, 404 and history against OpenAPI. Definitions are not yet evaluated;
status, events and deadlines are unchanged by saving them.

### Rule definition evaluation — 2026-09-17

Heartbeat and battery definitions now drive rule state. Saving a definition
restores the Thing's committed evidence claims and their single receiver
observation, evaluates the policy in live mode and stages any changed rule
state, history, event intent and public event in the same update transaction.
Materialising a Thing does the same for every live definition bound to it, using
the newly built observation and bundle. HTTP contract 1.13.0 reports rules as
`heartbeat_battery_definitions`. A deleted definition's rule is excluded from
scheduling and reported to the host scheduler as retired, while its status and
history remain readable. An ID can be defined again only with its first
version's kind and Thing.

Service tests establish a heartbeat baseline and a low battery baseline from
the RAWv2 fixture's 2.977 V reading, then recompute the battery rule to normal
with a live `battery.recomputed` intent that still requires separate
authorization. A later associated capture reporting 2.4 V becomes low when
materialised, at the materialisation's own generation, and replaying that
operation adds no rule version. Deleting a definition removes it from the
schedule; saving the same binding reactivates it with a new creation time and
revision, while another Thing and future snapshots conflict. A staged transition
with a stale prior state commits nothing, and an update rejects foreign-scope or
duplicate rule transitions. The independent HTTP consumer confirms the evaluated
battery status and policy identity after saving a definition.

### Browser rule creation — 2026-09-17

A provisioned asset now links administrators to `/assets/{id}/protection`.
Preparing a rule reads the current scope generation and patches a fresh
operation reference into the address before the form appears. The form offers
a reporting heartbeat for any provisioned asset and a low-battery-voltage rule
only when the Thing declares numeric `batteryVoltage` in volts. Seconds and
volts are validated locally, converted to the closed service parameters and
submitted once with the operation-derived rule ID. A committed receipt counts as
success only after the saved definition names the same asset; an unknown or
failed reply hides the form and can be checked through the retained receipt.

LiveView tests save a battery rule whose 3.0 V low threshold evaluates the RAWv2
fixture's 2.977 V reading as low, then reconnect to the receipt and open the
rule status. They refuse unprovisioned assets, reader sessions and forged
events; reject malformed seconds and thresholds before calling the service;
surface a stale generation without committing; recover a lost reply without a
second write; and keep unrelated receipts, transport failures and failed
verification reads uncertain. The optional app host serves the page through its
real loopback listener without disclosing the bearer.

### Browser rule editing and deletion — 2026-09-17

A rule status page now reads the service definition with the same ID and kind.
It links the defined asset, shows the definition revision and says when the
displayed status came from another revision. Host-managed rules and rules whose
definition was deleted state that no active definition exists. Administrators
can prepare an edit or deletion: the page captures the scope generation, patches
an operation reference and intent into the address and renders only the chosen
control. Edits reuse the shared seconds-and-volts form, keep the kind and asset,
and are offered only when stored durations are whole seconds for a
`batteryVoltage` or heartbeat rule. A committed receipt counts only after
reloading shows the definition present after an edit or absent after deletion.

LiveView tests edit a low battery rule to normal thresholds, see revision 5 and
the recomputed status, reconnect to the receipt, refuse a stale deletion after
another commit, and recover a lost deletion reply without a second write while
the rule leaves the host schedule. Readers and forged events cannot prepare
changes; sub-second parameters are not browser-editable; a same-ID definition of
another kind is not treated as the host rule's definition; unrelated receipts,
invalid operation references, transport failures and failed verification reads
stay uncertain. Form conversion tests cover thresholds, bounds and suspect
readings.

### Reviewed public rule events — 2026-09-17

Rule transitions and event-only rules copied their complete pure event into the
public `tracker.event` stream. Heartbeat events therefore disclosed caller
capture IDs, and other kinds disclosed evidence IDs and digests of private
samples, bundles, facts and transport decisions that ordinary projections never
show. Public events now use a reviewed projection that omits those references;
the privileged rule event intent keeps the complete event. Store schema 5 applies
the same removal to stored `tracker.event` documents, leaves other events
unchanged, and HTTP contract 1.14.0 reports that schema through readiness.

A service test commits all five rule kinds, reads their public events and finds
no capture ID or private reference field, while each public event equals the
projection of its stored intent. A version-4 database migration test confirms
that only `tracker.event` data loses those fields.

### Acknowledgeable rule alerts — 2026-09-17

Store schema 6 and HTTP contract 1.15.0 add public `alerts`. Every rule event
intent, whether from a stored transition, a definition or materialisation
evaluation, or an event-only rule, writes an alert record in its own
transaction. IDs embed an inverted generation so pages list newest alerts first.
Alerts carry the reviewed event, rule reference, mode, dispatch flag, evaluation
time and generation. The 5-to-6 migration backfills alerts for existing intents.

An administrator can acknowledge a live alert once through the ordinary receipt
contract. The acknowledgement records a time and actor pseudonym and publishes
`alert.acknowledged`; it changes no rule state and dispatches nothing. Service
tests list all five rule kinds' alerts newest first with exact projections and no
private references, replay the acknowledgement receipt, and reject reader,
second, stale, missing and malformed acknowledgements and replay-mode alerts.
A migration test backfills an alert equal to one written by the current store.
The independent HTTP consumer lists, acknowledges, fetches and pages an alert
against OpenAPI, including 403 and 409 outcomes.

### Browser alert review — 2026-09-17

`/protection/alerts` pages the service alert projection newest first, labels
known event kinds and marks each alert as needing review, acknowledged or a
replay record. `/protection/alerts/{id}` shows the rule, status change, reason,
recorded time, evaluation mode and that any physical Action needs separate
authorization or cannot be dispatched. An administrator prepares an
acknowledgement, which captures the scope generation and patches an operation
reference into the address; success is reported only after reloading shows the
acknowledgement.

LiveView tests list all five rule kinds in order without capture or evidence
references, refuse reader preparation and forged events, recover a lost
acknowledgement reply once, reconnect to its receipt, surface a stale generation
after another acknowledgement and reject an invalid operation reference. They
page 26 heartbeat alerts through transient failure, changed generation and
denial, show replay alerts without review controls, and keep unrelated receipts,
transport failures and failed verification reads uncertain. The optional app
host serves the alert list through its real loopback listener.

### Per-Thing rule definitions — 2026-09-17

HTTP contract 1.16.0 adds `GET …/things/{id}/policies`, backed by
`Service.thing_policies/5`. It returns, under current `read` authority and at one
committed snapshot, the at most eight live definitions bound to that Thing in ID
order, so a client need not scan every definition in the scope. A service test
separates two Things' definitions, drops a deleted definition, omits the private
actor and returns an empty list for an unknown Thing; the independent HTTP
consumer checks the list after saving and deleting a battery rule.

### Browser asset rule definitions — 2026-09-17

A provisioned asset's page now links every reader to `/assets/{id}/protection`.
That page reads the asset's live definitions through `Service.thing_policies/5`
at one committed snapshot and lists each definition's kind, ID, revision and
stored settings without rounding durations, linking it to its rule status. It
states how many of the eight permitted definitions exist. At eight it offers no
new rule, and a forged preparation reports the capacity limit instead of opening
the form. A failed list read leaves the count unknown, so the page offers no new
rule until a refresh succeeds. A committed save reloads the list before
reporting success.

LiveView tests list a battery and a heartbeat definition with exact settings and
status links for an administrator and a reader, refuse the reader any rule
preparation, keep the page usable through a failed list read and recover on
refresh, and stop preparation at eight definitions. The rule creation test sees
the newly saved definition in the list. The optional app host renders the page
heading through its real loopback listener.

### Administrator credential inventory — 2026-09-17

HTTP contract 1.17.0 adds `GET …/credentials`, backed by `Service.credentials/4`.
An administrator receives, in credential ID order, every host-configured
credential that grants a permission in the scope: its ID, principal, that
scope's sorted permissions, expiry, whether it is the calling credential and a
status. A durable revocation, read at the current committed generation, makes
the status `revoked` and reports its time, acting principal and generation;
otherwise the status is `expired` at host time or `active`. The pure
`Credentials.inventory/2` omits token digests, the secret key and other scopes'
grants, and the store reads at most 32 named revocation records under the same
admin reauthorization as other guarded reads. Accesses themselves are not
recorded, so this is an inventory rather than a complete access audit.

Service tests list three credentials of one scope with exact fields and no
digest, report a credential expired at its expiry time, list another scope's
grants for its own administrator, and reject readers, administrators of another
scope and invalid tokens. After two committed revocations the list reports both
as revoked, with revocation taking precedence over expiry, while the revoked
reader is denied ordinary reads. Store reads reject malformed and more than 32
IDs. The independent HTTP consumer validates the list against OpenAPI before and
after revoking the reader, including the reader's 403, the acting administrator
and the revocation generation.

### Browser credential inventory and revocation — 2026-09-17

The Access page now shows an administrator the service credential inventory for
the scope: each configured credential's ID, principal, permissions, expiry and
status, with a revocation's time and acting principal and a marker for this
browser's own credential. Readers do not see the inventory. An administrator can
prepare the revocation of another active credential: the page reloads the
inventory, captures its generation and patches the credential ID and a fresh
operation reference into the address before the confirmation form appears. The
current credential keeps its separate self-revocation flow. A committed receipt
counts as success only when its data names the same credential and the reloaded
inventory shows it revoked; a later failed check does not make a verified
revocation uncertain. Unknown replies and failed reads can be checked through
the retained reference without submitting again.

LiveView tests list both fixture credentials without bearer tokens or digests,
revoke the reader after an unconfirmed submission is refused, show the revocation
time and actor, reconnect to the receipt without a second write and deny the
revoked reader. They reject a stale generation without committing, refuse an
unrelated operation reference, an invalid reference, a missing reference, the
current credential and an already revoked credential, and keep the page usable
through unavailable and malformed inventory replies. A lost revocation reply
stays unknown while the inventory cannot be read and becomes revoked once it
can. Reader sessions cannot see the inventory, prepare a revocation or forge a
confirmation. The optional app host serves the inventory through its real
loopback listener without disclosing the bearer.

### Command-line credential inventory — 2026-09-17

`trackerctl credentials` reads `GET …/credentials` with the same bounded HTTP
client, JSON output and exit contract as other commands; it takes no arguments.
The independent CLI consumer checks against the provisioned host that the
operator credential created by `init` is listed as the current, active,
unrevoked `operator` credential at generation 0, and that an extra argument
is rejected with exit status 2 and `invalid_arguments`.

### Commit-following saved dashboards — 2026-09-17

Automatic refresh on a saved dashboard now follows committed changes instead of
rerunning every 30 seconds. Starting it reads the saved-query list for its
`stream_cursor` before running the query, so any commit not visible to that run
is after the cursor. Every 5 seconds the page reads one committed event batch
through `Service.events/5`. An empty batch changes nothing, except that a
rolling window reruns after six quiet checks because its bounds move with time.
A non-empty batch, an expired or invalid cursor, or a displayed stale result
takes a fresh cursor and reruns the query once, coalescing all pending commits.
The cursor advances only after a successful run, so a failed check or run keeps
the marked stale result and retries at the next check. Losing read authority or
the definition still stops following and clears the result.

LiveView tests show a quiet check running no query, a committed observation
rerunning it, failed runs and failed definition reads keeping the stale result
until a later check recovers without a new commit, a rolling window rerunning on
its sixth quiet check, unavailable and malformed event batches, an expired
cursor and unavailable or malformed snapshot reads recovering on the next check.
Changed definitions still reload, and deletion and revocation still stop following.

### Per-Thing rule alerts — 2026-09-17

Store schema 7 and HTTP contract 1.18.0 bind alerts to Things. When a rule event
writes its alert, the store reads the service definition with the same rule kind
and ID in the same transaction and records its `thing_id`, or null for
host-managed and event-only rules. A definition saved in that commit is already
visible, and definitions fix kind and Thing for an ID, so the binding cannot
change. The 6-to-7 migration applies the same lookup to existing alerts,
including those whose definition was later deleted. `Service.thing_alerts/6` and
`GET …/things/{id}/alerts` page one Thing's alerts newest first under `read`,
with a cursor that binds the Thing and page size.

A service test raises alerts for two Things' battery definitions and pages one
Thing's alerts one at a time into exactly that Thing's newest-first alerts. It
rejects a cursor used for another Thing, a changed page size, a plain alert-list
cursor, an empty Thing, malformed parameters and an invalid token, and returns
no alerts for an unknown Thing. A migration test binds an existing alert to the
Thing of a later-deleted same-kind definition and leaves an other-kind alert and
a host rule alert unbound. The schema 5 backfill still equals a newly written
alert. The independent HTTP consumer sees no alert after a normal battery
baseline, one bound alert after editing the thresholds to low, an empty list for
an unknown Thing, 400 and 401 outcomes, and the same alert after the definition
is deleted.

### Browser per-asset alerts — 2026-09-17

A provisioned asset's protection page now pages the alerts of its defined rules
through `Service.thing_alerts/6`, ten at a time and newest first. Each row links
the alert, names its rule, shows its recorded time and whether it needs review.
Moving to older alerts keeps up to 32 earlier page requests; returning reloads
that page under current read authority and refuses a page from a changed
snapshot. A failed page keeps the displayed alerts with a notice, a failed first
page or malformed reply shows that alerts are unavailable, and lost read
authority clears them.

LiveView tests raise more than ten alerts by editing a battery definition's
thresholds, then page older and newer alerts, keep the first page through an
unavailable older page, refuse returning to a newer page after another commit,
show the list to a reader, and cover unavailable, malformed and forbidden
replies.

### Command-line rule definitions and alerts — 2026-09-17

`trackerctl` now accepts `policies` and `alerts` for `list`, `inspect` and
`history`. `list policies --thing THING` reads one Thing's live definitions and
`list alerts --thing THING` pages its alerts with the ordinary `--limit` and
`--cursor` options. The CLI rejects `--thing` for other resources and paging
options for per-Thing definitions with exit status 2 and `invalid_arguments`. The
independent CLI consumer checks empty definition and alert lists for the scope
and the materialised Thing and both rejected forms. The CLI still cannot create,
change or acknowledge anything.

### Alert asset links — 2026-09-17

An alert page now links the asset protection page of the Thing whose rule
definition recorded it, or states that the host manages the rule when the alert
has no Thing. LiveView tests see the link on an alert from a battery definition
and the host-managed statement on a fixture battery alert.

### Administrator unenrollment — 2026-09-17

HTTP contract 1.19.0 adds `unenroll`, backed by `Service.unenroll/6` and
`POST …/unenrollments`. An administrator names one Thing and the expected
generation. The service reads its enrollment, Thing, current state and live rule
definitions at that generation and commits deletion tombstones for all present
records, with `enrollment.changed`, `thing.changed` and a deleted
`policy.changed` event per definition. Deleted definitions stop scheduling. Rule
status, alerts, observations, private evidence and record history are retained,
so unenrollment removes the asset from current views without erasing data. No
publication intent or physical Action is created.

Service tests unenroll a materialised Thing with heartbeat and battery
definitions, replay the receipt, and find the enrollment, Thing, state and both
definitions gone, the Thing's definition list and the enrollment list empty and
nothing scheduled, while rule status, raw observation export and a tombstoned
enrollment history remain. They reject readers, malformed requests, stale and
future generations and unknown Things, and refuse to materialise, define rules
for or unenroll the removed Thing. An open Property observation closes after the
unenrollment and a Property read returns `not_found`. Removing a never
materialised enrollment writes only that tombstone and event and leaves other
assets untouched. The independent HTTP consumer enrolls a second asset, gets 403
for a reader, unenrolls it, receives 404 for its enrollment and sees the deletion
in its history.

### Browser asset removal — 2026-09-17

An enrolled asset's page now links administrators to `/assets/{id}/remove`. The
page lists the consequences before anything is prepared, including how many rule
definitions will be deleted and that retained history, observations, evidence,
rule status and alerts stay. Preparing a removal captures the scope generation
and patches a fresh operation reference into the address; submitting requires a
confirmation checkbox and calls `Service.unenroll/6`. A committed receipt counts
only when it names this asset and the enrollment reads as not found. An unknown or
failed reply keeps the reference for a later check, and a stale generation closes
the form without committing.

LiveView tests remove a provisioned asset with a battery definition after an
unconfirmed submission is refused, find its enrollment and definitions gone,
reconnect to the receipt without a second write and see the asset list empty.
They refuse reader preparation and forged submission, surface a stale generation
after another commit, reject an unrelated or invalid operation reference, keep an
unavailable reply uncertain, and recover a lost reply once the enrollment can be
read as removed.

### Command-line unenrollment — 2026-09-17

`trackerctl unenroll THING --confirm --generation N` calls
`POST …/unenrollments` with the ordinary operation identity and receipt output.
Without `--confirm` it exits with status 2 and `confirmation_required` before any
request. The independent CLI consumer refuses the unconfirmed form, unenrolls its
associated and materialised Thing at generation 7, receives the unenrolled
receipt and then lists no Things before revoking its own credential.

### Per-Thing rule statuses — 2026-09-17

HTTP contract 1.20.0 adds `GET …/things/{id}/rules`, backed by
`Service.thing_rules/5`. Under `read` it returns, in definition ID order, the
reviewed status of every live rule definition bound to one Thing as `kind:id`
items. Each status is read at the generation of the definition list, so the
response describes one committed snapshot. A definition without recorded status
is omitted, and an unknown Thing has none.

A service test lists no statuses before definitions exist, then a low battery
and a current heartbeat status after saving both, each equal to its individual
rule read, drops the battery status after deleting its definition, returns
nothing for an unknown Thing and rejects an empty Thing and an invalid token.
The independent HTTP consumer checks the battery status against OpenAPI and the
individual rule read.

### Browser rule status on assets — 2026-09-17

Provisioned asset cards on the overview now read `Service.thing_rules/5` after
their committed state and list each defined rule's kind and status. Low,
overdue, degraded and outside statuses are marked as needing attention. A card
without definitions says so, a failed status read keeps the retained readings
and states that rule status is unavailable, and lost read authority clears the
list as before. The asset protection page shows the same status beside each
definition, `Not evaluated` for a definition without status and `Unavailable`
when the status read fails.

LiveView tests show a provisioned card with no rules, then a low battery rule
marked as needing attention, keep the temperature reading through an unavailable
status read and clear the cards on a forbidden one. The protection page test sees
low and on-time statuses and an unavailable status column.

### Command-line per-Thing rule status — 2026-09-17

`trackerctl list rules --thing THING` reads `GET …/things/{id}/rules`. Like
per-Thing definitions it accepts no paging options, and `--thing` remains limited
to rules, definitions and alerts. The independent CLI consumer lists no statuses
for its materialised Thing and receives `invalid_arguments` for a cursor with the
per-Thing status read and for `--thing` with Things.

### Browser session management — 2026-09-17

Each retained browser session now has a random non-secret handle and a wall-clock
start time. `Sessions.list/2` returns, for a live session, the live sessions that
hold the same credential and scope with their handle, start and expiry times and
which one is current. `Sessions.end_session/3` removes another such session by
handle; the service credential stays valid. Session identifiers and tokens never
leave the store, and token comparison uses constant time. The Access page lists
these sessions and offers to end every one except its own.

Session store tests list two administrator sessions but not a reader session,
disclose no session identifier or token, refuse to end a session of another
credential, the current session or an unknown handle, end the other
administrator session so its next request is unauthorized while the current one
continues, and reject listing or ending from an unknown session. A LiveView test
ends a second browser session from the Access page, sees one session remain and
reports an unknown handle.

### Incident snapshot saved queries — 2026-09-17

HTTP contract 1.21.0 adds a snapshot window to saved queries. A save with
`{"kind":"snapshot","generation":G,"result_identity":R}` requires G to equal its
expected generation, reruns the absolute query at G through the pinned analytics
path and stores `wtr.saved-query.v3` only if the result identity is R. Executing
the definition reruns the query at G and returns that result, or
`revision_mismatch` when retained data no longer reproduces R. An incident
snapshot therefore stays fixed while later commits change a live query over the
same bounds.

A service test saves the displayed mean at generation 1 after rejecting a forged
identity, a generation different from the expected one, an extra window field
and a non-canonical generation. After another reading changes the live mean
from 12.5 to 16.25, executing the snapshot still returns the displayed result;
a snapshot pinned at the later generation with the earlier identity conflicts;
and a stored identity changed below the store API reports `revision_mismatch`.
The independent HTTP consumer saves a snapshot of a displayed query after a 409
for a forged identity and executes it to the same result.

### Browser incident snapshots — 2026-09-17

The asset analytics save form now offers three window policies: a fixed time
range rerun on the latest data, a rolling window, and an incident snapshot of the
exact displayed result. The snapshot option sends the prepared scope generation
and the displayed result identity, so the service stores it only if nothing
superseded that result. The former label that called the absolute policy an
incident window was misleading, because that policy reruns on new data.

A LiveView test refuses a snapshot after a commit landed between displaying the
result and preparing the save, leaves no saved query, then saves a fresh result
as `wtr.saved-query.v3` pinned at generation 4. After another commit the saved
snapshot still executes to the same result identity, and its dashboard page runs
it.

### Recent operation receipts — 2026-09-17

HTTP contract 1.22.0 adds `GET …/operations`, backed by `Service.operations/5`.
Under `read` it pages the caller's own unexpired receipts in the scope, newest
first by commit generation and operation ID, with each operation ID, generation,
recording and expiry times and the stored receipt. The cursor binds the first
page's generation, principal, purpose and page size, so a page sequence excludes
later commits. Other principals' receipts and expired receipts are never listed.
A client that lost an operation reference can find its recent committed work.

A service test pages an enrollment and an import receipt one at a time, each
equal to the original receipt with its recording and expiry times, while a
materialisation committed between pages stays out of that sequence and leads a
fresh first page. The reader sees no receipts, receipts disappear at expiry, and
a changed page size, a malformed cursor, another principal's cursor, a resource
page cursor, malformed parameters and an invalid token are rejected. The
independent HTTP consumer lists its import receipt after the operation status
lookup, sees no receipts for the reader and gets 400 for a zero page size.

### Browser recent changes — 2026-09-17

A new Activity page, linked from the main navigation, pages the browser
credential's receipts from `Service.operations/5` ten at a time, newest first,
with a bounded path back to newer pages under current read authority. Each row
describes the committed change from its receipt data, including imports,
enrollment, provisioning, rule definition saves and deletions, alert
acknowledgements, dashboard saves and deletions, credential revocation and asset
removal, and links the record where one still exists. The page states that a
change missing from it had not committed when the page loaded.

A LiveView test commits eleven changes of those kinds, finds the newest ten with
their links, keeps the first page through an unavailable older page, reaches the
import on the second page, returns to newer changes, refuses a newer page from a
changed snapshot, and reports malformed and forbidden replies.

## WoTEx monorepo development seam — 2026-09-19

Coordinated development now resolves `wotex`, `wotex_runtime` and
`wotex_binding_http` from their package directories below the sibling `wotex`
monorepo. The workspace root is no longer misidentified as the `wotex` package.
Root, service, shared-UI and app-host dependency graphs compiled from those paths;
the Nerves headless, kiosk and QEMU profiles resolved the same graph. Every local
profile lock records the extra development-only packages selected by the upstream
monorepo's path-dependency contract. Published dependency metadata is unchanged.

The floor-runtime root gate passed with 1 doctest, 19 properties and 158 tests,
95.4% production line coverage, strict Credo, Dialyzer, documentation/contracts,
archive, dependency audit, licenses and stack-language checks. The immutable
source-cohort qualifier now clones the monorepo once at an exact detached revision,
checks only the required package paths for concurrent changes and builds each
package from that snapshot. Nerves source receipts likewise scope dirty-state
checks to the recorded package rather than unrelated monorepo work.
Six core source-archive consumers passed on both required runtime lanes in fresh,
locked and minimum modes with no new Tracker processes or optional hosts loaded.

At monorepo revision `a5920baaa4dfe350a4a564aff20eac23c4defd74`, the core and
Runtime verification reached and passed Runtime's complete package/archive gate.
The HTTP binding then passed 95 tests and 97.5% line coverage but its own complete
gate stopped on two unmatched-return Dialyzer findings in
`test/support/fake_client.ex`. No new source-cohort receipt is promoted until that
upstream gate is clean and the complete qualifier is rerun.

### Time-windowed operational graphs — 2026-09-19

The volatile collector now has a separate `window_page/2` contract that returns
one exact 25-row page and a graph projection from the same snapshot. The first
read pins a from-exclusive/to-inclusive UTC window, event filter, collector epoch
and sequence high-water mark. Its continuation also binds the page limit,
duration and first matching retained sequence. Later telemetry stays outside the
snapshot; changed inputs and restarts are invalid, and retention loss is reported
as an expired cursor. The graph returns the latest 1,000 matching samples and an
exact count of any earlier samples omitted from the projection, while those
samples remain reachable through exact pages.

The administrator view offers one-, five- and fifteen-minute windows. It projects
each closed nonnegative measurement at its actual elapsed position between the
window bounds, retains discrete marks rather than inferred lines, labels the UTC
bounds and reports projection omissions. Event and window responses are checked
against the requested values before display. Both app and Nerves host adapters
continue to authorize before and after every collector read.

The service gate passed 2 properties and 198 tests at 95.1% production line
coverage. The shared UI gate passed 115 tests at 95.0%; the browser-enabled app
host gate passed 22 tests at 95.5%; and the Nerves host UI profile passed all 7
tests. The root contract gate also passed 1 doctest, 19 properties and 158 tests
at 95.4% coverage. Compiler, unused-dependency, formatter, audit, strict Credo, ExDoc,
Dialyzer, package/archive, license, native host-tool and stack-language checks all
passed where applicable. Tests cover elapsed bounds, fixed high-water membership,
changed filters, retention expiry, the 1,000-sample disclosure boundary, sparse
measurements, elapsed-time coordinates, authorization, paging and malformed
responses.

### Checkpointed operational export — 2026-09-19

The collector now exposes ascending `wtr.operational-export.v1` batches through
an epoch-and-sequence checkpoint. A first read is explicitly a retained snapshot;
ordinary continuation emits no duplicate acknowledged sequence. Falling behind
retention reports the exact missing sequence count before resuming at the earliest
retained sample. A collector restart uses a new epoch and reports unknowable loss
rather than presenting a false continuous stream. Future, malformed and
over-specified checkpoints are rejected.

`OperationalExporter` is an optional host-supervised delivery loop over that
contract. It holds at most one batch, invokes the host adapter in a separate
monitored process with a finite timeout and advances only on acknowledgement.
Unavailable, rejected, crashing and sleeping adapters retry from the prior
checkpoint without blocking the collector or telemetry caller. Adapter context
is omitted from process inspection. The default HTTP host starts no exporter and
no remote service is needed for local operation.

The complete service gate passed 2 properties and 202 tests at 95.0% production
line coverage. Compiler, unused-dependency, formatter, dependency audit, strict
Credo, ExDoc, Dialyzer, boundary checks, OpenAPI validation, 81-member package
archive inspection, licenses and the 419-file stack-language policy all passed.
Tests cover ordered multi-batch delivery, no duplicate acknowledged samples,
retention and restart continuity, invalid checkpoints, retry identity, adapter
rejection, crash, timeout, configuration closure and diagnostic redaction.

### Unsaved analytics follow mode — 2026-09-19

The per-asset analytics page now offers an explicit follow mode after a
successful structured query. It captures the scope event cursor before its
first refresh and checks that cursor every five seconds. A later commit causes
one fresh authorized state read and query; the selected duration is retained
while the absolute UTC window moves to end immediately after the asset's newest
retained observation. Quiet checks do not execute analytics. A commit racing a
query stays visible to the next cursor check because the cursor advances only
after the query succeeds.

A temporary check or query failure retains the prior graph and exact table with
a visible stale state, then retries from a fresh snapshot. Forbidden,
unauthorized or missing state clears the result and stops following. Manual
queries, prompted queries, asset refresh, historical shift/zoom and save
preparation cancel the timer; an epoch guard prevents an already-delivered old
timer message from changing the page. Export terminal denial also cancels an
active follow timer.

LiveView workflow tests cover commit-driven window movement, temporary failure
and recovery, no rerun on a quiet cursor, explicit historical pause, obsolete
timer rejection, initial cursor-snapshot recovery, malformed cursor metadata,
manual stop and terminal authorization loss. The complete shared-UI gate passed
118 tests at 95.0% production line coverage, with compiler, unused-dependency,
formatter, dependency audit, strict Credo, ExDoc, Dialyzer, package archive,
license and stack-language checks all passing.

### Gap-honest route replay core — 2026-09-19

`Wotex.Tracker.RouteReplay` now admits a content-identified clock, quality,
time-gap, distance-gap and sample-page policy over complete `PositionSample`
values. It validates every evidence bundle, rejects duplicate identities and
sorts unordered inputs by event time, receiver time, evidence identity, bundle
identity and sample identity. A trusted fix is used directly; receiver time may
replace only a missing fix under the explicit fallback policy. An untrusted
supplied fix or a fix after reception is rejected rather than repaired.

The closed result retains exact qualified coordinates, source, quality, stated
accuracy, clock basis and evidence identities. Unavailable and filtered-quality
samples remain explicit rejections. A rejection or an adjacent time/distance
gap closes the current segment and records both surrounding sample identities,
elapsed time and WGS84 centre distance. Antimeridian distance uses the short
longitude delta, valid `(0, 0)` is retained, threshold equality stays connected
and no result invents a missing point, route or crossing time.

The complete root gate passed 1 doctest, 19 properties and 163 tests at 95.5%
production line coverage; the new module reached 98.5%. Compiler,
unused-dependency, formatter, dependency audit, strict Credo, ExDoc, Dialyzer,
documentation/contracts, 95-member archive inspection, licenses and the 421-file
stack-language policy all passed. Focused tests cover deterministic permutation,
repeated timestamp ties, antimeridian traversal, quality rejection, unavailable
positions, separate time and distance breaks, receiver fallback, untrusted and
future fixes, content identity, malformed policies, duplicate samples and hard
page bounds.

### Profile-backed position decoder seam — 2026-09-19

The trusted `Decoder` callback contract now returns exact bounded measurement,
position and identity collections. Each closed `wtr.position.v1` claim is
validated before evidence construction, content-identified with the source
observation and immutable catalogue snapshot, retained as position evidence and
constructed through the ordinary `Position` bundle validator. Stored decoded
values revalidate by deterministic reconstruction without rerunning callback
code.

Duplicate position claims, malformed coordinates, forged stored values and
receiver-observation lineage mismatches fail as `invalid_decoder_result` rather
than leaking a lower-level admission error or crashing validation. The Ruuvi
RAWv2 decoder now returns an explicit empty position list because its qualified
format has no location field.

The complete root gate passed 1 doctest, 19 properties and 164 tests at 95.4%
production line coverage. Compiler, unused-dependency, formatter, dependency
audit, strict Credo, ExDoc, Dialyzer, documentation/contracts, 95-member archive
inspection, licenses and the 421-file stack-language policy all passed. Focused
tests cover successful lineage/provenance export and exact revalidation plus
duplicate, malformed, wrong-receiver and forged stored position rejection.

### Configured service position projection — 2026-09-19

`Wotex.Tracker.Service` now accepts either its packaged Ruuvi defaults or a
closed host-supplied catalogue, compatible model and decoder registry. Registry
admission requires exactly one trusted unary callback for every decoder revision
referenced by the immutable catalogue. Resolution selects the inert revision
before lookup; missing, extra, duplicate, non-callable, forged-catalogue and
model-incompatible configurations fail explicitly.

Imported and materialised state now carries a bounded list of closed
`wtr.position-public.v1` projections. The public value preserves coordinates,
source, availability/quality, accuracy and qualified fix/receiver times with the
service's tagged scalar representation. Raw fields, source units, conversion
revision, receiver observation ID and evidence identities remain absent from
ordinary reads and present in authorized raw evidence export. The packaged Ruuvi
path returns the required empty list.

The complete service gate passed 2 properties and 204 tests at 95.0% production
line coverage. Compiler, unused-dependency, formatter, dependency audit, strict
Credo, ExDoc, Dialyzer, boundary checks, OpenAPI validation, 82-member package
archive inspection, licenses and the 423-file stack-language policy all passed.
Tests cover configured callback selection, import and materialisation projection,
private/public separation, exact required registry membership, duplicate and
wrong revisions, non-callables, forged catalogues and incompatible models.

### Shared retained-position presentation — 2026-09-19

The shared LiveView package now renders authorized `wtr.position-public.v1`
values on asset overview cards, asset details and retained state-history rows.
Each claim keeps its source, coordinate, stated accuracy kind/value, quality and
qualified fix/receiver times. Multiple sources stay separate; unavailable and
empty position collections remain explicit. Presentation text states that the
value is retained rather than live or fused and that no canonical position or
route was inferred.

Service projection now upgrades pre-position state documents at the read boundary
with an explicit empty position collection, leaving their stored historical
document unchanged. Position pages consume only the redacted public contract;
tests prove raw source content is absent. The default positionless Ruuvi workflow
continues to show an honest unsupported state.

The complete shared-UI gate passed 121 tests at 95.1% production line coverage.
Compiler, unused-dependency, formatter, dependency audit, strict Credo, ExDoc,
Dialyzer, 43-member package archive inspection, licenses and the 424-file
stack-language policy all passed. Workflow coverage exercises overview, detail
and history presentation; component coverage exercises valid, unavailable,
empty and malformed values without turning missing coordinates into `(0, 0)`.

### Managed motion and geofence definitions — 2026-09-19

Administrators can now persist closed motion and geofence definitions beside
heartbeat and battery policies. Motion admission reconstructs the complete
ordering, uncertainty, movement-threshold, plausibility and dwell policy through
the pure constructors. Geofence admission reconstructs bounded circle or polygon
geometry, boundary/uncertainty treatment, ordering and transition-gap policy. A
geofence definition identity binds both the geometry and transition policy, and
every edit receives the commit generation as its new revision.

Saving a definition evaluates the Thing's committed evidence in the same atomic
transaction. Later materialisations restore every definition and persist motion
candidate/trip or geofence membership transitions and stable alert intents at the
same generation. A bundle with exactly one position creates a complete
`PositionSample`; zero or multiple positions leave the rule unchanged, so the
host never invents an implicit source-selection policy. Malformed position
evidence fails closed.

OpenAPI contract 1.23.0 exposes all four definition kinds and reports
`heartbeat_battery_motion_geofence_definitions` in service capabilities. The
complete service gate passed 2 properties and 209 tests at 95.0% production line
coverage. Compiler, unused-dependency, formatter, dependency audit, strict Credo,
ExDoc, Dialyzer, boundary checks, OpenAPI validation, 82-member package archive
inspection, licenses and the 425-file stack-language policy all passed. Tests
cover circle and polygon policies, alternate clock/sequence/uncertainty modes,
closed-map rejection, policy-identity changes, durable entry/exit and trip-start
alerts, and missing, ambiguous or malformed position input.

### Shared position-rule management — 2026-09-19

The shared LiveView package now creates and edits the service's complete motion
and geofence definitions. Motion forms retain ordering, clock-skew, late-window,
sequence, uncertainty, speed/distance, plausibility, gap and dwell choices.
Geofence forms retain circle or bounded polygon geometry, boundary treatment and
transition gaps. Numeric admission preserves exact integer or floating-point
content, and an existing definition is editable only when every closed field can
round-trip through whole-second browser controls without change.

Creation presents all supported rule kinds while keeping unsupported battery
rules unavailable for Things without the qualified voltage property. The page
states that position rules consume only bundles with exactly one position and do
not select among multiple sources. Rule summaries distinguish motion, circles and
polygons without exposing evidence identities. Definitions outside the exact form
contract remain visible but must be edited through the service API.

The UI package now declares the test-only dependency required by the service test
support it deliberately compiles in the monorepo, keeping its test dependency
graph and lockfile consistent. The complete shared-UI gate passed 125 tests at
95.0% production line coverage. Compiler, unused-dependency, formatter,
dependency audit, strict Credo, ExDoc, Dialyzer, 43-member package archive,
license and 425-file stack-language checks all passed. Workflow coverage creates
both position-rule kinds and edits a motion definition without discarding its
host-committed transition state; focused form tests cover exact round trips,
polygon parsing, invalid admission and redacted summaries.

### Authorized retained route pages — 2026-09-19

The service now reconstructs bounded route replay from retained private evidence
through `Service.route_history/5` and the read-only `POST …/routes/pages`
operation. A first request pins the scope generation and an encrypted
continuation binds the exact Thing, half-open window, replay policy, page size,
principal, scope and service instance. Later writes stay outside the traversal
and every page rechecks current read authority, including each private source
observation fetch.

Each retained materialisation must restore a complete evidence bundle and one
source observation. Exactly one position becomes a `PositionSample`; missing and
ambiguous positions become pseudonymized exclusions that split otherwise
adjacent segments. Damaged retained evidence fails the whole page. Public points,
rejections and exclusions contain tagged scalar values and scoped pseudonyms,
never raw evidence, bundle, observation or sample identities. Each response
declares page-local continuity, so clients cannot infer a path between pages.

OpenAPI contract 1.24.0 publishes closed request, page, policy, route, point,
segment, break, rejection and exclusion schemas. The independent HTTP consumer
validates an actual route-page response against the served contract. The complete
service gate passed 2 properties and 217 tests at 95.1% production line coverage;
the new route module reached 98.3%. Compiler, unused-dependency, formatter,
dependency audit, strict Credo, ExDoc, Dialyzer, boundary checks, OpenAPI
validation, 83-member package archive inspection, licenses and the 427-file
stack-language policy all passed. Focused coverage includes missing/ambiguous and
malformed materialisations, quality rejection/inclusion, receiver fallback,
untrusted clocks, half-open windows, both antimeridian directions, ordinary
distance, snapshot isolation and cursor request/caller binding.

### Shared retained-route replay — 2026-09-19

The shared LiveView package now exposes an asset route-history screen over the
authorized service client. Readers select a half-open UTC window, trusted-fix or
explicit receiver fallback, accepted quality, adjacent time/distance gaps and a
25/50/100-materialisation page. The default one-day window ends immediately
after the asset's newest retained state. Positionless materialisations remain an
explicit empty replay with their exclusion reason.

The browser draws one SVG path for each returned service segment and supplies an
exact table of qualified coordinates, sources, clock basis, quality and stated
accuracy. It unwraps longitude around the antimeridian only for coordinate
projection. Breaks, quality rejections and missing/ambiguous materialisations
remain separately listed. The plot has no basemap, road matching or inferred
point. Every page warns that continuity is local, and paging never draws a
connector across responses.

Previous and next navigation rerun the encrypted request under current authority.
A temporary failure retains the current page and its back path; a terminal
authorization failure clears route data. Malformed result shapes fail closed.
The real local-service workflow exercises the positionless Ruuvi route, while
synthetic public pages cover multi-segment plots, antimeridian projection,
rejections/exclusions, forward/back navigation and retry behavior without private
evidence identifiers.

The complete shared-UI gate passed 130 tests at 95.0% production line coverage;
both the route screen and coordinate projector reached 95.2%. Compiler,
unused-dependency, formatter, dependency audit, strict Credo, ExDoc, Dialyzer,
45-member package archive inspection, licenses and the 430-file stack-language
policy all passed.

### Reauthorized route-page export — 2026-09-19

The route-history screen now exports one displayed public page only after rerunning
its exact cursor-bound request under current service authority and reproducing the
same content identity. The bounded `wtr.route-page-export.v1` document retains the
Thing, snapshot, retained-history interval, requested window, page-local
continuity declaration and complete public replay. It reports whether another
page existed but omits the encrypted continuation cursor, so the file cannot
resume or authorize traversal.

A temporary service failure emits no download and leaves the current page
visible. A changed page identity clears the stale result; forbidden,
unauthorized or missing data clears route state. Tests decode the download,
verify its positionless exclusion and cursor absence, then cover temporary retry,
identity conflict and terminal denial.

The complete shared-UI gate passed 130 tests at 95.0% production line coverage;
the route export module reached 100%. Compiler, unused-dependency, formatter,
dependency audit, strict Credo, ExDoc, Dialyzer, 46-member package archive
inspection, licenses and the 431-file stack-language policy all passed.

### Snapshot-pinned trip lifecycle pages — 2026-09-19

The service now exposes `Service.thing_trips/6` and read-only
`GET …/things/{id}/trips` pages over the already committed public motion alerts.
The storage query selects only `trip.started`, `trip.stopped` and
`trip.interrupted` for the requested Thing, so battery, geofence and other
alerts cannot consume the bounded page. Results remain exact event records; the
service does not infer missing endpoints or claim a completed distance summary.

The encrypted continuation is distinct from a generic alert cursor and binds
the current principal, scope, service instance, Thing, immutable generation and
page size. Later commits stay outside a traversal and current `read` authority is
checked for every page. An unknown Thing produces an empty page. OpenAPI contract
1.25.0 publishes the endpoint and a closed `TripEventPage`, advertises the
capability explicitly and is exercised by the independent HTTP consumer.

The complete service gate passed 2 properties and 220 tests at 95.1% production
line coverage. Compiler, unused-dependency, formatter, dependency audit, strict
Credo, ExDoc, Dialyzer, boundary checks, OpenAPI validation, 83-member package
archive inspection, licenses and the 432-file stack-language policy all passed.
Focused coverage proves event-kind and Thing filtering, immutable continuation
snapshots, endpoint/caller/Thing/page-size cursor binding, closed query admission,
unknown Things and authorization failure.

### Cursor-bound trip time windows — 2026-09-19

Trip lifecycle pages now accept optional paired `from_at` and `to_at` Unix
millisecond bounds over the event's effective time. The interval is half-open.
Filtering occurs in the snapshot SQL query alongside the Thing and closed event
kind set, so out-of-window or unrelated alerts cannot consume a page. A
continuation carries the exact bounds inside its authenticated payload; clients
cannot alter or partially resupply the window while continuing a traversal.

OpenAPI contract 1.26.0 publishes the two bounded query parameters and the
independent HTTP consumer exercises canonical parsing and malformed-bound
rejection. Focused service tests cover boundary inclusion/exclusion, cursor
continuation and missing, equal or cursor-mixed bounds.

The complete service gate passed 2 properties and 221 tests at 95.1% production
line coverage. Compiler, unused-dependency, formatter, dependency audit, strict
Credo, ExDoc, Dialyzer, boundary checks, OpenAPI validation, 83-member package
archive inspection, licenses and the 434-file stack-language policy all passed.

### Shared trip and stop timeline — 2026-09-19

The shared LiveView package now links every provisioned asset to an authorized
trip-history screen. It pages the dedicated service boundary at 25, 50 or 100
events and presents exact starts, stops and interruptions newest first with UTC
effective, confirmation and recording times, reason, rule revision, evaluation
mode and the retained trip identifier. Each event links to its complete public
alert record.

Endpoint pairing is explicitly page-local. When a start and stop or interruption
are both visible, the screen reports their exact effective-time interval. A lone
start or ending remains visibly partial; navigation never carries an endpoint
across pages and the UI claims neither a distance nor a reconstructed route.
Malformed pages and any event containing a private observation, evidence,
sample, bundle, fact or decision identity fail closed.

Previous and next navigation retain the current page on temporary failure and
preserve a bounded newer-page path. The displayed event page is exported only
after rerunning its exact cursor-bound request under current authority and
matching the snapshot, records and continuation state. The bounded
`wtr.trip-event-page-export.v1` document contains public events but no service
page or stream cursor. Changed content clears the stale page and terminal denial
clears trip data.

The complete shared-UI gate passed 133 tests at 95.0% production line coverage;
the trip export reached 100% and the trip screen 95.2%. Compiler,
unused-dependency, formatter, dependency audit, strict Credo, ExDoc, Dialyzer,
48-member package archive inspection, licenses and the 434-file stack-language
policy all passed. The real local-service workflow covers an empty authorized
timeline and export; synthetic public pages cover endpoint pairing, replay
labelling, retry-safe forward/back navigation, changed generations, malformed
and private-field-bearing pages, export conflicts and terminal denial.

### Trip-history window and presentation controls — 2026-09-19

The shared trip screen now submits a strict half-open UTC effective-time window
to the dedicated service boundary. Its default covers the 30 days ending one
millisecond after the newest retained asset state. First-page requests carry the
window and page size; continuations remain cursor-only because the service binds
the original window into the authenticated cursor. Every returned event is also
checked against the selected window before presentation.

Readers can display event times at one of a closed set of fixed minute offsets
and can show exact onset-to-ending intervals in milliseconds or decimal seconds.
The screen states that fixed offsets do not follow daylight-saving changes and
does not claim IANA timezone behavior. Integer milliseconds remain the source of
every interval; seconds use at most three exact fractional digits without
floating-point rounding.

The cursor-free page export now records the numeric service window plus the
timezone key, label, fixed offset and duration unit used to present it. Export
still reauthorizes and reproduces the exact displayed page. Tests cover strict
UTC admission, invalid timezone/unit rejection, half-open response validation,
fixed-offset timestamps, exact fractional seconds and both default and selected
export metadata.

The complete shared-UI gate passed 133 tests at 95.0% production line coverage.
Compiler, unused-dependency, formatter, dependency audit, strict Credo, ExDoc,
Dialyzer, 48-member package archive inspection, licenses and the 434-file
stack-language policy all passed.

### Authorized completed-trip distance summaries — 2026-09-19

The service now exposes `Service.trip_summary/6` and read-only
`GET …/things/{id}/trips/{trip}` for one immutable completed trip. Inside one
reauthorized SQLite read snapshot it resolves exactly one retained start and one
stop or interruption, proves the rule belongs to the requested Thing, restores
the exact motion state committed with the start and rebuilds its position cohort
through the terminal event. Reconstruction is capped at 100 exact samples and
uses the motion policy and revision active when the trip began.

Only adjacent segments proved moving contribute to centre, lower and upper
distance totals. Stationary, indeterminate and unknown segments remain explicit
public exclusions and are never bridged. The content-identified
`wtr.trip-summary.v1` projection contains terminal context and the complete
public segment ledger, but strips every observation, evidence, bundle, sample
and private policy identity. Active, unknown and incomplete trips receive no
final summary; missing, ambiguous, corrupt or noncanonical retained inputs fail
explicitly, and an oversized cohort returns `capacity_exceeded` without a
truncated result.

OpenAPI contract 1.27.0 publishes the endpoint, closed summary schemas and the
`bounded_gap_honest_reconstruction` capability. A separate BEAM HTTP process
validates the real response against the served contract, verifies an unknown
trip response and rejects private identity leakage. Focused tests cover active,
stopped and rule-revision-interrupted trips, preservation of the start-policy
revision, wrong Thing binding, malformed IDs, ambiguous position cohorts and
damaged retained rule, evidence, observation and event rows.

The complete service gate passed 2 properties and 226 tests at 95.1% production
line coverage; the private reconstruction input module reached 100%. Compiler,
unused-dependency, formatter, dependency audit, strict Credo, ExDoc, Dialyzer,
boundary checks, OpenAPI validation, 85-member package archive inspection,
licenses and the 436-file stack-language policy all passed.

### Shared final trip-distance presentation — 2026-09-19

The shared trip timeline now links each retained stop or interruption to a
dedicated final-distance route. The screen requests only the public authorized
service operation and admits its exact closed `wtr.trip-summary.v1` shape. It
shows centre, lower and upper canonical metres, complete or partial status,
terminal timing and policy revision, then tabulates every adjacent included or
excluded segment. The browser never recalculates distance, bridges exclusions or
constructs a route.

Recursive admission rejects observation, evidence, bundle, sample and private
policy identities as well as wrong Thing/trip bindings, malformed timelines,
inconsistent counts, bounds, totals and identities. A temporary service failure
keeps the last valid summary for retry; terminal denial, changed content and
malformed results clear it. Oversized and noncanonical cohorts receive explicit
messages and never a truncated or invented total.

Export reruns the exact Thing/trip operation under current authority and requires
the immutable summary identity to match. The bounded
`wtr.trip-summary-export.v1` document contains the complete public summary but no
credential, service cursor or private reconstruction input. The local browser
hook downloads it as JSON.

The complete shared-UI gate passed 134 tests at 95.1% production line coverage;
the final-summary screen reached 98.2% and its export module 100%. Compiler,
unused-dependency, formatter, dependency audit, strict Credo, ExDoc, Dialyzer,
50-member package archive inspection, licenses and the 438-file stack-language
policy all passed.

### Final-distance units and timezone controls — 2026-09-19

The final trip summary now shares the timeline's closed set of fixed UTC offsets
and adds metre, kilometre and international-mile distance presentation. Service
metres remain the canonical source and stay visible on screen. Kilometres divide
by 1,000; international miles use exactly 1,609.344 metres; both are labelled as
display-only and rounded to three decimal places. Fixed offsets are explicitly
not daylight-saving-aware.

Presentation submission admits exactly the timezone and distance-unit fields and
rejects unknown values without discarding the valid summary. Every total, bound,
included segment and event time uses the selected presentation consistently;
excluded segments remain excluded instead of becoming zero. Reauthorized export
retains the complete canonical summary and now records the timezone key/label,
fixed offset, unit conversion and rounding declaration.

Focused workflow tests cover UTC/metres defaults, positive and negative fixed
offsets, kilometre and mile conversions, canonical-metre retention, invalid
control admission and export metadata. The complete shared-UI suite passes 134
tests at 95.2% production line coverage; the final-summary screen reaches 98.6%
and its export module 100%.

### Closed owner-presence fact admission — 2026-09-19

The service now conditionally admits a complete serialized `owner.present`
`PolicyFact` for an enrolled Thing. Admission restores and content-validates the
closed observation/evidence bundle, requires exact or strong identity evidence
associated with that Thing and retains the entire fact privately. The current
fact advances only on a strictly later receiver observation; stale and same-time
conflicting evidence cannot replace it. Missing state and radio silence never
become absence.

The reviewed `wtr.owner-presence.v1` resource exposes only present, absent or
unknown, observation and admission times, a commit-derived revision and a scope
pseudonym of the admitting actor. List, get and history use ordinary authorized
snapshot/cursor semantics, and unenrollment records a current-state tombstone.
Observation, evidence, bundle and fact identities do not enter the projection.
Admission evaluates no suspicious-movement rule, delivers no notification and
dispatches no physical Action.

OpenAPI contract 1.29.0 publishes admission and public list/get/history schemas.
A separate BEAM HTTP process validates actual requests and responses against the
served contract, proves reader denial and checks that private fact markers are
absent from the wire projection. The complete service gate passed 2 properties
and 234 tests at 95.1% production line coverage. Compiler, unused-dependency,
formatter, dependency audit, strict Credo, ExDoc, Dialyzer, boundary checks,
OpenAPI validation, 87-member package archive inspection, licenses and the
443-file stack-language policy all passed.

### Atomic staged event-only rule intents — 2026-09-19

An authorized service mutation can now carry up to eight independently
revalidated `RuleEvent` intents beside its records and state transitions. The
store writes each new private intent, reviewed public event and alert at the
triggering mutation's generation inside the same `BEGIN IMMEDIATE` transaction.
An exact stable duplicate creates no second event or alert; a same-ID content,
mode or physical-effect collision aborts the entire mutation. No canonical rule
state is manufactured for an event-only rule.

Tests stage a suspicious-movement event with an authorized update, verify its
single alert, retry it in a later mutation without duplication, reject a live/
replay collision without advancing generation, reject duplicate intents during
admission and inject a pre-commit failure that leaves neither intent nor alert.
The complete service gate passed 2 properties and 235 tests at 95.1% production
line coverage, together with compiler, formatting, dependency audit, strict
Credo, ExDoc, Dialyzer, boundary, OpenAPI, archive, license and language-policy
checks.

### Exact suspicious-movement policy definitions — 2026-09-19

Administrators can now persist an event-only `suspicious_movement` definition
for an enrolled Thing. Admission requires an existing motion definition for the
same Thing, restores it at the requested generation and embeds that exact motion
policy in the private suspicious policy document. The public projection exposes
only its outer content identity and the reviewed motion reference, fact-age,
future-skew and unknown-presence parameters. It does not disclose the nested
policy, fixed predicate names or acting principal.

Definition restoration revalidates both public/private documents and every
cross-binding before use. Invalid parameters, self-reference, missing or
wrong-Thing motion rules and damaged stored policy content fail closed. Saving
the definition creates no synthetic rule state. The OpenAPI contract advances to
1.30.0 and the separate BEAM HTTP consumer validates actual definition saves,
reads and Thing-scoped pages against the served schemas while checking private
markers are absent from the wire response.

The complete service gate passed 2 properties and 236 tests at 95.1% production
line coverage. Compiler, unused-dependency, formatter, dependency audit, strict
Credo, ExDoc, Dialyzer, boundary checks, OpenAPI validation, 87-member archive
inspection, licenses and the 443-file stack-language policy all passed.

### Atomic suspicious-movement orchestration — 2026-09-19

The service now reevaluates every live suspicious-movement definition for a
Thing when that definition is saved, its exact motion state changes during
materialisation, or its arming or owner-presence fact changes. Staged inputs take
precedence over the preceding snapshot. The referenced live motion definition
must retain the exact identity privately embedded in the suspicious policy;
changed or deleted motion bindings, missing inputs, stale facts and non-true
three-valued results emit nothing.

A true result becomes a revalidated event-only intent, reviewed public event and
Thing alert at the triggering mutation's generation. Triggering records, motion
state, private intent and alert commit or roll back together. Exact operation
replay does not duplicate the event, private motion/fact/evidence identities stay
out of the public alert, and no notification or physical Action is dispatched.

Integration tests exercise every enabling-input order, explicit present/absent
and policy-controlled unknown presence, stale exact-motion binding suppression,
motion-definition deletion, damaged motion/fact storage, injected rollback and
the independent HTTP/OpenAPI consumer. OpenAPI contract 1.31.0 describes the
atomic behavior. The complete service gate passed 2 properties and 246 tests at
95.1% production line coverage. Compiler, unused-dependency, formatter,
dependency audit, strict Credo, ExDoc, Dialyzer, boundary checks, OpenAPI
validation, 88-member archive inspection, licenses and the 445-file
stack-language policy all passed.

### Shared event-only suspicious-movement management — 2026-09-19

The asset protection workflow now offers suspicious movement only after the
asset has a live motion definition. Creation binds a selected motion-definition
ID and admits whole-second fact-age and future-skew limits plus the explicit
unknown-owner-as-absent choice. The screen explains that the service captures
the exact motion policy, that changing or deleting it suppresses the binding,
and that the definition produces reviewed alerts rather than current state.

Definition lists label the rule `Event-only · alerts only` instead of reporting
it as unevaluated or unavailable. Its dedicated route falls back from the absent
status projection to the authorized public definition, exposes no current-state
or history controls, and supports recoverable generation-checked edits and
deletion. A missing motion definition disables editing while leaving deletion
available. Alert presentation names the event without exposing the privately
embedded motion policy or predicate names.

Focused component and LiveView tests cover closed parameter conversion,
round-trip admission, motion-option gating, create/read/edit/delete recovery,
absence of a synthetic rule row, public-policy redaction and stale binding
presentation. The complete shared-UI gate passed 139 tests at 95.0% production
line coverage. Compiler, unused-dependency, formatter, dependency audit, strict
Credo, ExDoc, Dialyzer, 51-member archive inspection, licenses and the 445-file
stack-language policy all passed.

### Shared reviewed owner-presence presentation — 2026-09-19

The asset arming screen now reads the authorized public owner-presence resource
beside the committed arming fact. It admits only the exact
`wtr.owner-presence.v1` shape, presents present, absent or unknown with observation,
admission and revision context, and never receives the retained observation,
evidence bundle or fact identity. Missing state and radio silence are explicitly
unknown rather than absent, and the shared browser offers no control that could
manufacture or edit presence evidence.

Temporary read failures retain the last validated public presence fact for retry;
terminal denial or malformed projections clear it. The arming confirmation now
states that the service reevaluates exact suspicious-movement bindings inside the
same transaction while notification delivery and physical Actions remain
separate. Workflow coverage exercises missing, absent, present and explicit
unknown facts, private-reference exclusion, malformed revisions, unavailable
reads and current-authority denial.

The complete shared-UI gate passed 140 tests at 95.0% production line coverage;
the protection-input screen reached 97.4%. Compiler, unused-dependency,
formatter, dependency audit, strict Credo, ExDoc, Dialyzer, 51-member archive
inspection, licenses and the 445-file stack-language policy all passed.

### Reviewed suspicious-alert trigger conditions — 2026-09-19

The shared alert detail now explains a suspicious-movement event in terms of its
reviewed historical conditions: confirmed movement and active trip, armed state,
and either explicit owner absence or the rule revision's explicit treatment of
unknown presence as absence. The page warns that current facts may differ and
continues to present notification and physical-Action delivery as separate from
the canonical alert.

The presentation consumes only fields already retained in the public event and
does not request or render motion-state, policy-fact, observation, bundle or
evidence identities. Workflow tests cover both admitted owner interpretations,
a malformed interpretation fallback, active-trip context and the absence of all
private reference names.

The complete shared-UI gate passed 141 tests at 95.0% production line coverage;
the alert detail reached 96.1%. Compiler, unused-dependency, formatter,
dependency audit, strict Credo, ExDoc, Dialyzer, 51-member archive inspection,
licenses and the 445-file stack-language policy all passed.

### Supervised notification delivery boundary — 2026-09-19

The explicit service host can now supervise one caller-configured notification
dispatcher. Its bounded worker claims only minimal APNs reference items from the
durable forward queue, binds each claim to the exact encrypted endpoint revision
and rechecks the retained administrator access proof against current configured
grants, expiry and durable revocation before invoking the adapter. No provider is
selected when the dispatcher is absent.

Provider acceptance records application acknowledgement without claiming OS
delivery or a user read. Retryable, malformed, crashing and timed-out adapter
outcomes remain pending for the durable retry policy. Missing, rotated and
revoked endpoints and permanent provider rejection have distinct terminal
receipts. An invalid-token result conditionally tombstones only the revision that
was sent; concurrent rotation preserves the replacement, and concurrent
revocation prevents the cleanup mutation and leaves the item retryable.

Tests cover notification-only claiming, isolation from ordinary forwarding,
exact queue identity and claim requirements, acceptance, retries, malformed and
crashing adapters, worker timeout, endpoint removal and rotation, authorization
revocation, invalid-token cleanup, concurrent rotation/revocation, terminal
outcome races, supervised store discovery, unavailable storage and redacted
status. The complete service gate passed 2 properties and 275 tests at 95.0%
production line coverage. Compiler, unused-dependency, formatter, dependency
audit, strict Credo, ExDoc, Dialyzer, boundary checks, OpenAPI validation,
93-member package archive inspection, licenses and the 453-file stack-language
policy all passed.

### Explicit APNs provider transport — 2026-09-19

The service package now includes an opt-in APNs adapter over Mint HTTP/2 and
verified TLS. Hosts supply an Apple team ID, key ID, unencrypted P-256 `.p8`
contents and closed bundle-topic list directly. The adapter decodes and validates
the key, excludes it from inspection, constructs an ES256 JWT with current
whole-second issue time and never reads an ambient key path or application
setting. Sandbox and production endpoint selection comes only from the retained
endpoint binding.

Every request uses explicit topic, alert push type, priority, zero expiry and UUID
headers. The uncompressed body contains generic reviewed copy plus only the opaque
event-reference schema and ID. Both request and response bodies, response headers,
deadline and accepted endpoint hosts are bounded. Provider responses distinguish
acceptance, invalid device tokens, rate limiting, retryable server/transport
failure and permanent rejection without claiming device delivery or user reading.

Tests verify the raw JOSE signature against the generated P-256 key, exact JWT
claims, sandbox/production hosts, headers and minimal payload; closed key/topic/
copy/timeout admission; private inspection; all provider outcome classes;
malformed targets and payloads; signing, clock and transport failure containment;
passive HTTP/2 request construction; fragmented response assembly; response-size
and header limits; connection/request/receive/close failures and total deadline
expiry. The complete service gate passed 2 properties and 284 tests at 95.0%
production line coverage. Compiler, unused-dependency, formatter, dependency
audit, strict Credo, ExDoc, Dialyzer, boundary checks, OpenAPI validation,
96-member package archive inspection, licenses and the 457-file stack-language
policy all passed.

### Remote current-access projection — 2026-09-20

The service now exposes one authenticated `wtr.access.v1` projection through
its facade and versioned HTTP API. It returns only the current credential's
non-secret ID and principal, the exact requested scope's sorted grants and the
configured expiry after current read authorization and durable revocation
checking. Bearer material, token digests, access proofs, the instance secret and
other-scope grants never enter the response. Invalid, expired and durably revoked
credentials receive no projection.

The shared UI's in-process adapter now derives login capabilities, the Access
screen identity and the current-credential revocation context from that same
projection. This removes the previous local-only permission probing and gives a
future mobile HTTP adapter one explicit versioned authority document without
changing browser session custody.

Tests cover administrator and reader projections, sorted exact permissions,
expiry, absence of the bearer token, invalid credentials and the HTTP envelope.
The complete service gate passed 2 properties and 285 tests at 95.0% production
line coverage, and the complete shared-UI gate passed 141 tests at 95.0%.
Compiler, unused-dependency, formatter, dependency audit, strict Credo, ExDoc,
Dialyzer, boundary checks, OpenAPI validation, 96-member service and 51-member UI
archive inspection, licenses and the 457-file stack-language policy all passed.

### Versioned remote presentation client — 2026-09-20

The shared presentation package now implements every existing closed UI client
action over the versioned service HTTP surface. Its explicit production origin
must use HTTPS; numeric loopback HTTP is opt-in for the real integration test.
The one-shot Mint HTTP/1 transport uses passive receives, verified TLS and the
host trust store, admits no redirect, applies one absolute deadline and bounds
request bodies, response bodies, headers and header counts. Credential material
is sent only in the Authorization header and is excluded from retained adapter
state and inspection.

Paths, methods, accepted query names, resource names and mutation routes come
only from the adapter's closed mapping. JSON responses require the exact
`wtr.response.v1` envelope and expected media type; login, identity and current
revocation context additionally require the exact `wtr.access.v1` projection.
Each mutation is sent once with its original operation UUID. Transport failure,
timeout or malformed acknowledgement remains `unknown` under that UUID, while
reads fail unavailable, so callers recover through durable receipt lookup
without automatic mutation replay.

An actual loopback service test exercises authorization, a three-parameter trip
page and committed observation admission through Mint. This exposed and fixed
the service wire's former two-pair query ceiling; it now admits at most four
unique pairs, matching the trip paging contract, and rejects a fifth. Boundary
tests cover every shared action mapping, percent encoding, exact headers,
malformed configuration, projections, envelopes, media, identities, queries and
JSON; fragmented and connection-closing responses; cold module loading; all
transport phases, deadlines and size limits; and private exception containment.

The complete service gate passed 2 properties and 285 tests at 95.1% production
line coverage, and the complete shared-UI gate passed 152 tests at 95.2%.
Compiler, unused-dependency, formatter, dependency audit, strict Credo, ExDoc,
Dialyzer, boundary checks, OpenAPI validation, 96-member service and 54-member UI
archive inspection, licenses and the 461-file stack-language policy all passed.

### Mint HTTP parser security update — 2026-09-20

Every committed service, shared-UI, application-host and Nerves dependency
profile now resolves Mint 1.10.1, closing the response-smuggling issue reported
as CVE-2026-82672. The exact version is pinned at the package and composed
application seam; headless, UI-enabled and QEMU lock files were regenerated
rather than leaving an older transitive parser in a deployment profile.

The complete service gate passed 2 properties and 285 tests at 95.1% production
line coverage, and the complete shared-UI gate passed 152 tests at 95.2%.
Compiler, unused-dependency, formatter, dependency audit, strict Credo, ExDoc,
Dialyzer, boundary checks, OpenAPI validation, 96-member service and 54-member UI
archive inspection, licenses and the 473-file stack-language policy all passed.
Dependency audits additionally passed for the headless and UI-enabled ordinary
application and Nerves host profiles. The QEMU dependency audit passed on its
qualified OTP 29.0.4 / Elixir 1.20.4 host toolchain, matching the target's OTP
major version.

### Account-bound offline mobile projection cache — 2026-09-20

The independent mobile host now pins Mob 0.9.1 with Elixir 1.19.5 / OTP
27.3.4.15 while leaving the root and other hosts on their existing runtime
floor. Its first executable component is a serialized SQLite cache restricted
to overview, history, dashboard and map projections. Every read identifies its
offline source, synchronization age, completeness and credential-expiry bound;
empty and stale entries remain explicit misses.

The database lives only below an absolute private nonsymlink directory, uses a
private regular file, strict tables, full synchronization and secure deletion,
and validates its schema and integrity on reopen. Entry bytes, total bytes,
count, retention age, JSON shape and nesting are bounded. The retained binding
is a length-prefixed hash of the exact canonical HTTPS origin, principal, scope,
credential ID and secure-storage installation ID. No binding identity is stored
in clear text. Switching any bound component, credential expiry and explicit
sign-out securely purge the cache. Credential-, token-, proof-, raw- and
authorization-shaped fields are rejected, and no offline mutation or physical
Action queue exists.

Tests cover all four projection classes, restart recovery, expiry boundaries,
same-credential renewal, every account-binding component, delimiter-bearing
identities, secure purge, least-recently-used count/byte eviction, stale
retention, malformed and oversized projections, unsafe paths and file modes,
future/malformed/corrupt SQLite state, closed-database failures and concurrent
writers. The complete mobile-host gate passed 16 tests at 95.3% production line
coverage. Locked dependency resolution, compiler, unused-dependency, formatter,
dependency audit, strict Credo, ExDoc, Dialyzer, licenses and the 474-file
stack-language policy all passed. CI now selects the mobile host's exact runtime
cohort independently from the 1.18 host profiles.

This is offline-cache software evidence only. Local LiveView/Mob composition,
platform secure storage, lifecycle/reconnect behavior, native bridges, Xcode,
signing and every physical-iPhone acceptance gate remain unpassed.

### Capability-bound local mobile WebView shell — 2026-09-20

The mobile host now starts the shared LiveView router behind a bounded Bandit
listener fixed to numeric IPv4 loopback and presents it in one Mob WebView. A
canonical random 32-byte capability is used only for the initial bootstrap URL.
The endpoint stores its SHA-256 digest in an encrypted and signed HTTP-only,
SameSite-strict cookie, requires the binding for every later HTTP request and
LiveView mount, and retains only that binding through sign-in, sign-out and
session renewal. Static assets are behind the same gate. The capability is
absent from rendered content, socket assigns, logs and inspected runtime state.

The WebView admits only the exact local-origin prefix. The endpoint enforces the
same exact WebSocket origin and disables long-poll, HTTP/2, debug errors and code
reloading. Canonical external HTTPS navigation is opened by the OS rather than
inside the bridge-bearing view. No development distribution listener or cookie
is started. Remote requests invoke the Mob DNS seam before the shared bounded
Mint transport while preserving the selected HTTPS scheme, host, port and
request. Resolver and transport crashes fail as unavailable; ordinary host tests
use the BEAM resolver when the device NIF is absent.

End-to-end tests exercise unauthorized HTTP/static requests, wrong and oversized
bootstrap capabilities, encrypted-cookie attributes, sign-in and sign-out
renewal, shared UI rendering, bearer-token non-disclosure, exact remote request
paths, static bridge assets and foreign WebSocket-origin rejection. Pure tests
cover canonical local targets, malformed capabilities, external-navigation
admission, resolver outcomes, native-start containment and host configuration.
The complete mobile-host gate passed 28 tests at 95.6% production line coverage;
the complete shared-UI gate passed 154 tests at 95.1%. Compiler,
unused-dependency, formatter, dependency audit, strict Credo, ExDoc, Dialyzer,
archive inspection, licenses and the 491-file stack-language policy passed for
their applicable profiles.

This is software loopback-shell evidence, not physical mobile qualification.
Platform secure credential storage, cache/view synchronization, lifecycle and
reconnect behavior, notification routing, BLE central provisioning, OS sharing,
Xcode generation/build, signing, installation, distribution and every
physical-iPhone gate remain unpassed.

### Device-only iOS secure-storage primitive — 2026-09-20

The mobile host now carries an app-owned, iOS-only Mob plugin for exactly two
secure-storage slots: an opaque credential envelope and a random installation
identifier. Its statically linked Objective-C NIF stores generic-password
Keychain items under a fixed service name with
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and
`kSecAttrSynchronizable` set to false. Items therefore stay on the device and
are not silently restored from backup or synchronized through iCloud Keychain.
There is no preferences, browser-storage or ordinary-file fallback.

The BEAM wrapper admits only the two closed keys, bounds values to 4 KiB and
contains absent-NIF, malformed-result, exception, throw and exit failures as
`unavailable`. Native calls run as dirty I/O NIF jobs; error results expose no
secret or raw OS status. The committed Mob configuration activates the plugin
and explicitly acknowledges its repository-owned unsigned source so the native
code cannot enter a build as an unlisted dependency.

Host tests cover both slots, replacement, deletion, bounds, widened keys,
malformed adapters, every contained failure class, absent native linkage and
the packaged manifest/source invariants. The complete mobile-host gate passed
32 tests at 95.6% production line coverage; all compiler, unused-dependency,
formatter, dependency-audit, strict Credo, ExDoc, Dialyzer, license and 498-file
stack-language checks passed. Apple clang also accepted the Objective-C NIF with
ARC and warnings-as-errors against the installed macOS SDK and OTP 27 NIF
headers.

This proves a checked native primitive, not physical Keychain behavior. The
credential envelope is not yet integrated with sign-in, cache binding, server
switching or logout, and no signed iPhone backup/restore, protected-data or
unavailable-Keychain test has run. Those gates remain open.

### Account-bound mobile credential lifecycle — 2026-09-20

The mobile host now owns one fail-closed lifecycle across shared UI sessions,
device-only credential storage and the projection cache. Shared session login
obtains one exact access projection and asks an optional host custodian to retain
the bounded token, scope, access and opaque session identifier before making the
session visible. A custody failure leaves no browser session. Mobile composition
limits the store to one session and persists an exact seven-field credential
envelope containing only its schema, canonical service origin, bearer token,
scope, credential ID, principal and expiry. Process status and inspected state
are redacted.

The lifecycle creates a canonical random installation ID in secure storage and
binds the cache to that ID plus the authenticated origin/account projection.
Cold start validates the closed envelope, binds the cache, reauthorizes through
the versioned remote access endpoint and creates a fresh volatile session. An
offline start retains an existing binding without granting browser authority and
retries reauthorization at a later native bootstrap. Unauthorized, expired,
malformed, widened and foreign-origin envelopes are removed and the cache is
purged. Sign-out deletes the secure credential and cache binding before retiring
the browser session; a storage failure preserves the existing session so the
user can retry instead of receiving a false sign-out. Dead-cache and hostile
secure-store callbacks are contained, and a failed restoration discards its
newly issued volatile session.

Tests exercise HTTP sign-in/sign-out custody, cold host restart, offline recovery,
revocation, expiry, origin switching, malformed envelopes and installation IDs,
secure-store read/write/delete failure, exceptions and throws, dead-cache
rollback, status redaction and exact cache binding. The complete mobile-host gate
passed 41 tests at 95.6% production line coverage, and the complete shared-UI
gate passed 155 tests at 95.1%. Compiler, unused-dependency, formatter,
dependency-audit, strict Credo, ExDoc, Dialyzer, archive inspection, license and
stack-language checks passed for their applicable profiles.

This remains software evidence using a deterministic secure-store test seam. It
does not establish physical Keychain behavior, protected-data availability,
signed backup/restore behavior or remote erasure of an offline device. Shared
views still do not populate or present the offline cache, and notification,
native lifecycle, BLE, sharing, signing and physical-iPhone gates remain open.

### Labelled offline mobile presentation — 2026-09-20

The mobile host now composes the shared remote client with its account-bound
projection cache. Successful authorized reads synchronize only the closed
overview, history, dashboard and route-map classes under a deterministic digest
of the exact action and argument map. A service-unavailable response may read
only that exact key. Authorization denial, malformed responses and all other
errors remain authoritative and never reveal cached data. Mutations, raw
evidence, access management and operation recovery are neither cached nor
queued, and a cache write failure cannot turn a valid remote read into failure.

Every cached result gains an explicit offline projection with source,
synchronization timestamp, age, completeness and credential-expiry bound.
Shared browse, asset, trip, trip-summary, route and dashboard screens render
that state without widening their normal response shapes. A cold offline start
may create a new volatile session only from an unexpired, origin/account-bound
device credential. Its local identity grants no enrollment, ingestion, raw-read
or query-management capability, so mutation controls stay unavailable while
cached reads remain usable. Sign-out, account changes, expiry and invalid stored
credentials still purge the binding.

Tests exercise all four cache classes, exact-key misses, incomplete-page labels,
remote denial over cached content, conservative offline identity, mutation and
raw-read exclusion, dead-cache and hostile-callback containment, cold offline
host bootstrap and rendered synchronization labels. The complete mobile-host
gate passed 47 tests at 95.4% production line coverage, and the complete
shared-UI gate passed 156 tests at 95.0%. Compiler, unused-dependency, formatter,
dependency audit, strict Credo, ExDoc, Dialyzer, 56-member UI archive inspection,
licenses and the 503-file stack-language policy passed for their applicable
profiles.

This is local software evidence. No physical iPhone, protected-data transition,
network handoff, background/foreground lifecycle, push notification, BLE,
sharing, Xcode, signing or distribution gate was exercised.

### Bounded mobile lifecycle recovery — 2026-09-20

The root Mob screen now subscribes only to application and network lifecycle
events. A completed background-to-active transition reloads the current local
WebView once; duplicate active callbacks do nothing. Losing a network path is
recorded without an effect, and regaining it while active likewise performs one
reload. Recovery therefore re-enters the existing loopback session gate and
shared client, where online policy is re-evaluated and expired snapshots are
resampled. It introduces no mutation queue, retry loop, arbitrary native method
or page-controlled JavaScript—the sole effect is a fixed internal reload.

The transition reducer is independent of native state, and subscription,
malformed callbacks, invalid native results, exceptions and throws are
contained. Tests cover background/foreground ordering, duplicate callbacks,
offline/online recovery, fixed-effect invocation and integration with the real
root screen. The complete mobile-host gate passed 49 tests at 95.2% production
line coverage. Compiler, unused-dependency, formatter, dependency audit, strict
Credo, ExDoc, Dialyzer, licenses and the 504-file stack-language policy passed.

This does not claim that a suspended BEAM keeps running. Physical suspend,
process eviction, reboot, Wi-Fi/cellular handoff, reconnection latency, memory
pressure and energy acceptance remain unexecuted on an iPhone.

### Bounded mobile notification registration and routing — 2026-09-20

The mobile host now pins and activates the signed MobNotify 0.1.2 plugin and can
optionally supervise one APNs registration owner for an explicit bundle-style
application ID and `sandbox` or `production` environment. The root native screen
requests notification permission, asks iOS for a provider token only after a
grant and best-effort removes the endpoint after denial. The shared remote client
exposes only the existing service notification-endpoint list, registration and
deletion resources; all work still passes through the current bounded,
authorized mobile session.

The registrar derives a stable endpoint identifier from a domain-separated
SHA-256 digest of the device-only installation ID. Registration, rotation and
removal first read the exact server generation and submit a deterministic UUIDv4
operation identity. Provider tokens are bounded to printable ASCII, never enter
the projection cache, secure credential envelope or status output, and are
cleared after a successful operation. A token received before sign-in or during
service unavailability may remain only in the status-redacted volatile process;
credential retention and lifecycle recovery retry it without an automatic
mutation loop.

Notification input admits only the exact two-field
`wtr.notification-reference.v1` data projection. A bounded valid UTF-8 opaque
event reference is percent-encoded into the fixed local protection-alert route,
where the existing shared screen reauthorizes and fetches current state. Extra
fields, private content, malformed references, widened provider events and
native exceptions, throws or invalid results cannot navigate the WebView.

Tests cover registration and token rotation, deterministic operation shape,
generation and response failures, absent endpoints, permission denial,
pre-authentication retry, redaction, installation-bound endpoint identity,
configuration closure, permission/token callbacks and exact tap routing. The
complete mobile-host gate passed 56 tests at 95.4% production line coverage, and
the complete shared-UI gate passed 156 tests at 95.0%. Compiler,
unused-dependency, formatter, dependency audit, strict Credo, ExDoc, Dialyzer,
56-member UI archive inspection, licenses and the 507-file stack-language policy
passed for their applicable profiles.

This is software-boundary evidence. No Xcode host was generated, and no signed
build, Push Notifications entitlement, provisioning profile, AppDelegate token
forwarding, APNs provider exchange or physical delivery/tap test ran. The current
Mob callback presents notification payloads through one software event shape;
cold-start, warm, foreground and background tap behavior therefore remains an
explicit physical-device gate rather than an inferred claim.

### Closed mobile sharing of authorized exports — 2026-09-20

The shared UI's eight existing JSON export events now preserve their ordinary
Blob-download behavior in a browser and select the native path only when Mob's
original WebView bridge was present before the LiveView hook mounted. The native
request has one exact `wtr.mobile-share.v1` shape containing a fixed filename,
fixed JSON media type and the already-produced content. It cannot name a native
function, URL, filesystem path or new fetch.

The root Mob screen passes that message through a closed validator before
calling the system text share sheet. Six public export filenames require their
exact query, history, route or trip export schema. The separately authorized raw
observation and evidence downloads accept only a JSON object or array. Every
payload must be valid UTF-8 JSON no larger than 1 MiB and have exactly four
bridge fields. Extra fields, unknown filenames, schema substitution, scalar or
invalid JSON, oversize input and native exceptions or throws produce no native
effect. The share boundary performs no service request itself: the originating
LiveView has already repeated the export's existing authorization and identity
checks immediately before emitting the content.

Tests exercise all eight allowed contracts, browser/native asset wiring,
invalid media and schemas, widened messages, raw scalar rejection, UTF-8 and
size bounds, absent NIF containment and root-screen integration. The complete
mobile-host gate passed 58 tests at 95.6% production line coverage, and the
complete shared-UI gate passed 156 tests at 95.0%. JavaScript syntax, compiler,
unused-dependency, formatter, dependency audit, strict Credo, ExDoc, Dialyzer,
56-member UI archive inspection, licenses and the 509-file stack-language policy
passed for their applicable profiles.

This is a checked software bridge to Mob's text-sharing API, not physical-device
evidence. No iPhone share sheet opened in this run, no receiving application was
selected, and no handoff fidelity, cancellation, memory-pressure or accessibility
behavior was observed. Those checks remain part of the signed-device gate.

### Bounded iOS BLE central transport — 2026-09-20

The mobile host now carries an app-owned CoreBluetooth plugin because the pinned
first-party Bluetooth plugin exposes only the peripheral role. Its closed command
contract provides filtered scan/stop, connect/disconnect, filtered service and
characteristic discovery, read and confirmed write. Scans require one to eight
canonical service UUIDs and a caller deadline of at most 30 seconds; every other
native operation has a fixed 30-second deadline. The cache holds at most 64
peripherals, returned values and writes are capped at 512 bytes, and native
results cross back into the packaged UI only through a validated 16 KiB event
envelope.

The bridge retains only CoreBluetooth peripheral identifiers and operation
owners. It does not accept BLE addresses, select a device, persist values,
interpret a tracker protocol, decide identity or map GATT into WoT. Unexpected
disconnects are reported to the connection owner and pending operations fail
closed. The packaged browser asset can forward only the fixed command schema
through the existing session-bound Mob screen; malformed, widened, noncanonical,
oversized and native-failure inputs produce no widened native effect.

Host tests exercise every admitted command and event, rejection and containment
paths, manifest activation, fixed framework/usage description and native source
bounds. The complete mobile-host gate passed 64 tests at 95.6% production line
coverage, and the complete shared-UI gate passed 156 tests at 95.0%. Compiler,
unused-dependency, formatter, dependency audit, strict Credo, ExDoc, Dialyzer,
archive inspection, licences and the 516-file stack-language policy passed for
their applicable profiles. Apple clang accepted the Objective-C NIF with ARC,
blocks and warnings-as-errors against the installed macOS SDK and OTP 27 NIF
headers.

This is software-boundary evidence, not iPhone or tracker interoperability
evidence. The development host has no iPhoneOS SDK, generated Xcode project,
signed installation or selected target service/characteristic profile. Real
permission behavior, radio lifecycle, provisioning and the upstream `wotex_ble`
adapter remain explicit physical and integration gates.

### Shared notification-installation management — 2026-09-20

The shared Access page now lists the administrator principal's registered mobile
notification installations through the existing public service contract. It
admits only the exact token-redacted endpoint projection and displays the opaque
installation ID, application ID, APNs environment and registration/update times.
Provider tokens and the service's pseudonymous internal record identity never
reach the page. Readers cannot see or remove installations, and an administrator
sees only installations owned by the current principal rather than a fictional
scope-wide hardware inventory.

Removal captures the current scope generation and a stable operation reference
in the page address, explains that canonical alerts remain and requires explicit
confirmation. A committed receipt is accepted only when it names the exact
installation and a fresh authorized list proves that record absent. Stale writes,
malformed projections, foreign or unrelated receipts and read-only attempts fail
closed. A lost response remains unknown until durable receipt recovery and the
fresh list agree; it is never submitted automatically. The local adapter now
exposes the same closed removal action already supported by the remote mobile
adapter.

Tests cover token redaction, exact projection admission, reader denial, explicit
confirmation, cancellation, stale generation, malformed lists, missing records,
lost-reply recovery, unrelated operations and reconnect through the retained URL.
The complete shared-UI gate passed 159 tests at 95.0% production line coverage.
Compiler, unused-dependency, formatter, dependency audit, strict Credo, ExDoc,
Dialyzer, 56-member archive inspection, licences and the 516-file stack-language
policy passed.

This manages only registered notification delivery installations for the current
principal. It is not a general device inventory, remote device wipe or physical
APNs-delivery claim. Complete access audit, retained-data deletion and retention
management remain open privacy work.

### Durable successful-access audit — 2026-09-20

Store schema 8 adds a separate durable access-audit journal and per-scope
coverage metadata. Every successful facade authorization and explicit stream
delivery reauthorization records the configured credential ID, principal,
required permission, closed service activity and receiver time before authority
is returned. The audit stores no bearer token, digest, proof, request body or
resource identifier and does not advance the domain generation. Invalid tokens,
denied grants and revoked credentials do not manufacture successful-access rows.
The version 7 migration adds empty audit tables and therefore makes no claim
about access before migration.

The journal retains at most 10,000 entries per scope for 30 days. Cleanup occurs
inside the next successful authorization transaction; expiry or capacity
removal sets a durable truncation marker. An administrator can page the newest
entries through `Service.access_audit/5` or `GET …/access_audit`. Its encrypted
cursor binds principal, scope, page size and the first page's sequence snapshot.
Every page discloses the coverage start, retention, capacity and truncation
state. Readers cannot inspect it. OpenAPI contract 1.34.0 includes the exact
entry/page shapes and the independent HTTP consumer checks the real endpoint,
reader denial and token non-disclosure.

Tests cover exact projections, failed-auth exclusion, pagination with later
commits, changed limits, malformed/future cursors, restart persistence, the
30-day equality boundary, capacity eviction and unchanged domain generation.
The complete service gate passed 292 tests and two generated properties at 95.0%
production line coverage. Compiler, unused-dependency, formatter, dependency
audit, strict Credo, ExDoc, Dialyzer, boundary checks, 99-member archive
inspection, OpenAPI audit, licences and the 520-file stack-language policy passed.

This is a bounded audit of successful service authorization decisions, not an
operating-system login log or a record of rejected credential guesses. Shared UI
presentation, retained domain-data deletion and configurable domain retention
remain separate work.

### Shared successful-access presentation — 2026-09-20

The shared Access page now admits and presents the successful-access journal for
administrators through both local and bounded remote adapters. It pages newest
first and shows the exact receiver time, principal, configured credential,
required permission and closed service activity. The page repeats that rejected
sign-in attempts are outside this journal and that bearer credentials, request
bodies and resource identifiers are omitted. It also exposes the coverage start,
fixed 30-day retention, 10,000-entry capacity and durable truncation disclosure.
Readers do not request or render the journal.

The presentation validates the exact seven-field page and six-field entry shapes,
closed permission vocabulary, identifiers, timestamps, snapshot, cursor, bounds
and maximum page size before replacing the current view. Temporary service
failure or a malformed later response leaves the last valid page visible with an
error. Tests exercise a real 27-entry journal across pages, return to the newest
snapshot, token non-disclosure, failure preservation, malformed-response
rejection and reader exclusion. The remote client tests its exact encoded GET
mapping and rejects non-map parameters.

The complete shared-UI gate passed 160 tests at 95.0% production line coverage.
Compiler, unused-dependency, formatter, dependency audit, strict Credo, ExDoc,
Dialyzer, 56-member archive inspection, licences and the 520-file stack-language
policy passed. The UI-enabled application-host gate passed 22 tests at 95.5%
coverage together with its compiler, formatter, strict Credo, ExDoc, Dialyzer,
native CLI build/format, dependency audit, licences and stack-language policy.

This closes shared presentation of the successful-access journal. Retained
domain-data deletion and configurable domain retention remain separate privacy
work; physical Pi and mobile acceptance also remain open.

### Recoverable retained-domain-data deletion — 2026-09-20

OpenAPI contract 1.35.0 adds administrator-only `GET …/privacy` and
`POST …/domain_data_deletions`, backed by `Service.privacy/4` and
`Service.delete_domain_data/6`. The preview reports exact counts for observations,
non-access record versions, events, publications, queued deliveries, rule state,
rule-event intents and operation receipts at the current scope generation. It
also reports preserved credential revocations and successful-access rows, the
last deletion marker, and the limits of the erasure claim.

Deletion requires the exact confirmation phrase, a current expected generation
and a stable operation identity. One immediate transaction removes every listed
domain category and prior receipt, advances the scope generation, then writes a
minimal privacy marker, public deletion event and caller-recoverable receipt.
Old event cursors fail after the erased sequence. A repeat returns the original
receipt; stale generations conflict; injected failure before commit preserves
all rows; lost acknowledgement or process exit after commit resolves through
the receipt. Durable access revocations and the separately bounded successful-
authorization audit survive, so erasure neither reactivates access nor removes
its security journal.

The managed SQLite connection enables secure deletion of freed cells. The API
still makes only a managed-primary-store claim: a pre-deletion consistent backup
is independently restored in the test and retains the old data, while offline
exports and already-remote publications are likewise reported as not deleted.
Concurrent readers can defer WAL reclamation, so the contract does not claim
that every historical physical byte disappears at commit.

The independent HTTP process validates preview, reader denial, the destructive
request and receipt, post-delete empty resources, and the retained marker against
the served OpenAPI document. The complete service gate passed 297 tests and two
generated properties at 95.1% production line coverage. Compiler,
unused-dependency, formatter, dependency audit, strict Credo, ExDoc, Dialyzer,
boundary checks, OpenAPI validation, licences, 100-member archive inspection and
the 522-file stack-language policy passed.

This completes the durable service deletion boundary. Shared application
presentation and configurable automatic domain retention remain separate work;
backup/export/remote-destination deletion remains operator-managed by design.

### Shared retained-data deletion presentation — 2026-09-20

The shared package now exposes an administrator-only Privacy page through the
same local and bounded remote service adapters. It presents exact retained
primary-store and preserved-security counts, the current generation, the last
deletion marker and the fixed access-audit bounds. The page explicitly excludes
consistent backups, offline exports and already-remote publications from the
deletion claim. Reader credentials neither request nor render the counts or the
destructive form.

Preparation refreshes the exact privacy projection, captures that generation
under a stable operation reference in the address, and requires the literal
`delete retained domain data` phrase. Submission occurs once. An ambiguous reply
removes the form and recovers through the durable operation receipt. Even a
committed receipt is not presented as success until a fresh exact projection has
the same generation, matching deletion timestamp and removed counts, plus only
the privacy marker, deletion event and current receipt among managed domain rows.
Malformed projections preserve the last admitted preview; stale generations
close without deleting newer state; unrelated receipts fail closed.

Workflow tests exercise exact preview, typed confirmation, current-session
survival, reconnect recovery, a deliberately lost acknowledgement, stale-write
refusal, malformed-preview preservation, reader exclusion and the closed remote
HTTP mapping. The Privacy link is part of the shared layout used by browser and
kiosk hosts. The complete shared-UI gate passed 166 tests at 95.0% production
line coverage, with compiler, unused-dependency, formatter, dependency audit,
strict Credo, ExDoc, Dialyzer, 57-member archive inspection, licences and the
523-file stack-language policy. The UI-enabled application-host gate passed 22
tests at 95.5% coverage together with its compiler, formatter, strict Credo,
ExDoc, Dialyzer, native CLI build/format, dependency audit, licences and
stack-language policy.

This completes the recoverable shared deletion workflow. Configurable automatic
retention remains open, and deletion of operator-managed backup/export/remote
copies remains outside the application by design.

### Configurable whole-scope inactivity retention — 2026-09-20

Hosts may now opt into `privacy_policy.domain_inactivity_retention_ms` from one
minute through one year; omission preserves the administrator-deletion-only
default. The exact policy, interval and one-minute background enforcement period
are visible in `GET …/privacy` and the shared Privacy page. OpenAPI contract
1.36.0 admits both policy modes and requires every deletion marker and public
deletion event to distinguish `administrator` from `automatic_inactivity`.

The store calculates activity only from domain mutation evidence: public domain
events, non-deletion operation commits, rule evaluation/event times and queued
delivery admission. Successful reads and the separate access audit do not extend
the interval. Every service authorization enforces the exact boundary before a
read or write, while a store-owned periodic check deletes an idle scope without
waiting for another request. Deletion uses the existing immediate transaction,
preserves credential revocations and the bounded access audit, invalidates old
event cursors and writes a minimal marker/event at the next generation. It does
not invent an administrator operation receipt, and deletion-only metadata is
excluded from activity so an empty scope is not repeatedly rewritten.

Tests cover the millisecond before and at the boundary, preserved revocation,
old-cursor rejection, no repeated deletion, no-request periodic enforcement,
automatic-policy presentation and a fault injected before commit that leaves all
domain rows intact before a successful retry. The closed private host
configuration rejects unknown fields and intervals outside its bound. The
managed-store claim remains unchanged: backups, offline exports and already
remote publications still require operator-managed expiry and deletion.

The complete service gate passed 303 tests and two generated properties at
95.1% production line coverage. The shared-UI gate passed 167 tests at 95.0%,
the default application-host gate passed 12 tests at 95.7%, and the UI-enabled
host gate passed 22 tests at 95.5%. Their compiler, unused-dependency, formatter,
dependency audit, strict Credo, ExDoc, Dialyzer, OpenAPI, archive, native CLI,
licence and stack-language checks passed wherever configured.

### Anti-stalking abuse analysis and public safety disclosure — 2026-09-20

The maintained abuse analysis now maps covert attachment, replayed identity,
credential theft, evidence erasure, permission bypass, undisclosed retention,
physical Action and compromised-ingress cases to the repository's implemented
software controls and residual risks. It makes hardware-specific unauthorized-
association detection, physical permission-denial evidence, device provisioning,
labelling and signed cross-surface acceptance explicit production blockers. It
does not promote operator confirmation, radio presence or a software alert to
hardware authentication or phone-vendor-scale unwanted-tracker detection.

Every shared host now serves `/safety` without requiring an account or service
request. The page states those limits, distinguishes the current controls from
unfinished hardware safeguards, links authenticated operators to access,
retention and enrollment review, and supplies an incident-response checklist.
Its static availability is not presented as a detection result. The composed
browser-host test fetches it before sign-in, verifies `no-store` delivery and
checks that neither service nor model credentials appear in the response.

The complete shared-UI gate passed 168 tests at 95.0% production line coverage,
including compiler, unused-dependency, formatter, dependency audit, strict Credo,
ExDoc, Dialyzer, 58-member archive inspection, licences and the 525-file stack-
language policy. The UI-enabled application-host gate passed 22 tests at 95.5%
with its configured BEAM, native CLI, dependency, licence and policy checks.
Real hardware anti-stalking qualification remains unpassed.

### Scope-authorized dashboard link sharing — 2026-09-20

Every admitted saved dashboard now displays one relative sharing link containing
only its public route identifier. The page states that the link contains no
credential and grants no access. A recipient must establish a separate session
for the same deployment and scope; loading the definition and every query run
continue through current read authorization. No public bearer link, cached result
or new dataset grant is created.

The shared workflow saves a rolling dashboard as an administrator, opens its
exact link as a different read-only principal, executes and exports the result,
then revokes that credential. The open view redirects at the next authority
check, and reopening the unchanged shared link also redirects to sign-in. The
complete shared-UI gate passed 168 tests at 95.0% production line coverage with
its compiler, formatter, strict Credo, ExDoc, Dialyzer, dependency, licence,
58-member archive and 525-file stack-language checks. The UI-enabled application-
host gate passed 22 tests at 95.5% with every configured check.

### Shared semantic accessibility baseline — 2026-09-20

A reusable test-only document audit now parses the initial full HTML for 18
primary shared routes: public safety, assets, setup, asset detail, analytics,
route, trips, arming, asset rules/removal, dashboard detail/index, operational
history, protection/alerts, activity, access and privacy. It requires an explicit
document language, exactly one main landmark and page heading, non-skipping
heading order, unique IDs, resolvable ARIA references, labelled controls, named
links/buttons/regions, captions for every table and accessible alternatives for
graphics. Wrapped labels and decorative empty-alt images retain their standard
HTML semantics.

Independent negative fixtures trigger every checked failure class together, so
the acceptance is not a set of presence-only assertions. The complete shared-UI
gate passed 171 tests at 95.0% production line coverage with compiler, formatter,
strict Credo, ExDoc, Dialyzer, dependency audit, licences, 58-member archive
inspection and the 527-file stack-language policy. The UI-enabled application-
host gate passed 22 tests at 95.5% with every configured check. Manual keyboard,
screen-reader, contrast, zoom, touch and gesture evidence on physical browser,
Pi and iPhone surfaces remains unpassed.

### Bounded browser reconnect telemetry — 2026-09-20

The shared browser now supplies a fresh connection-parameter function to its
LiveSocket. Its first successful open flips only an in-memory marker, so later
attempts by that same socket are marked as reconnects while a reload creates a
new initial connection. The host bridge accepts only marked Phoenix socket
events for its exact endpoint and LiveView socket type. Successful and rejected
attempts become `connection.stop` samples with integer microsecond duration and
only the closed `browser` surface, `reconnect` kind and `ok`/`unavailable`
outcome. CSRF values, paths and every other socket parameter are discarded.

The service contract, collector filter and browser operational documentation
now include this event. Tests reject initial connections, another endpoint,
negative durations and injected extra metadata; the composed HTTP test also
checks that the served adapter contains the dynamic reconnect marker without
containing service or provider credentials. The render bridge allowlist now
covers every current shared root LiveView without admitting components or
unrelated views.

JavaScript syntax validation passed. The complete service gate passed 304 tests
and two generated properties at 95.1% production line coverage. The shared-UI
gate passed 171 tests at 95.0%, the headless application-host gate passed 12
tests at 95.7%, and the UI-enabled host gate passed 23 tests at 95.6%. Their
configured compiler, unused-dependency, formatter, dependency audit, strict
Credo, ExDoc, Dialyzer, OpenAPI, archive, native CLI, licence and 527-file
stack-language checks passed. OS-native resource telemetry and physical
reconnection acceptance remain unpassed.

### Bounded Nerves native-resource telemetry — 2026-09-20

The headless and kiosk Nerves profiles now supervise a resource sampler beside
the shared HTTP service. Its production source reads only the fixed Linux paths
`/proc/meminfo`, `/proc/self/status` and `/proc/loadavg` at startup and every 30
seconds, admitting at most 65,536 bytes from each. A complete sample contains
nonnegative integer system available-memory bytes, BEAM OS-process RSS bytes and
one-minute load multiplied by 1,000. Missing, malformed, negative, overflowing
or oversized source data produces no partial or invented sample.

The service's closed telemetry vocabulary and volatile collector now admit
`native.sample` with exactly those three measurements and only `nerves` surface
plus `linux_procfs` source metadata. Tests exercise exact parsing, malformed and
oversized files, unavailable-source process survival, rejected extra
measurements and retention through the real collector. They also verify that the
sampler is supervised in the composed appliance without changing service
failure isolation. No path, PID, scope, device identity or credential is stored.

The complete service gate passed 305 tests and two generated properties at
95.1% production line coverage. The shared-UI gate passed 171 tests at 95.0%
with the new event available through its contract-derived filter. Headless
Nerves host verification passed 7 tests and the kiosk composition passed 10,
both with warnings-as-errors and formatter checks. Configured dependency audit,
strict Credo, ExDoc, Dialyzer, OpenAPI, 100-member service archive, 58-member UI
archive, licences and the 530-file stack-language policy passed. This is host
software evidence; real Pi resource behavior, budgets and other native-surface
adapters remain unpassed.

### ARM64 virtual native-resource boot proof — 2026-09-20

The Nerves QEMU-only boot fixture now withholds its success marker until three
conditions hold together: the private SQLite file exists, the guest-loopback
health endpoint answers and the service's supervised operational collector
contains a `native.sample`. Its bounded poll runs after the application tree
starts; an empty or unavailable collector fails the probe instead of treating
process startup as resource evidence. Unit fixtures cover delayed arrival and
each failed condition. The recorder requires the exact expanded success marker
on both boot logs and records separate native-sample checks.

The updated `qemu_aarch64` firmware cross-built with Elixir 1.20.4, ERTS 17.0.6,
Nerves 1.15.0 and the pinned QEMU system/toolchain. Firmware SHA-256 is
`a2fbbb57b4d1ef86ac084ca7fdd8345150088b8b7033c46beed19611781e7dfe`.
QEMU 11.1.1 booted a freshly generated ignored disk, formatted its application
partition, started the private store and passed the native-resource probe. A
second boot of the same disk did not format the partition and passed the same
probe. The two full serial-log digests and resolved release inventory are in
`verification/nerves-qemu-boot.json`.

The receipt identifies Tracker commit `228ddf0c52316443bc506d56e66e976bc720ce3e`
and explicitly lists the pre-existing uncommitted WTR.15 documentation path; the
boot/runtime source changes themselves were committed before the recorded run.
All sibling WoTEx source cohorts were clean. Headless host verification passed 8
tests and the kiosk composition passed 11 with warnings-as-errors and formatter
checks. This is virtual ARM64 Linux evidence, not a Pi 5 boot, resource budget,
display/radio test or hardware acceptance.

### Bounded standalone Linux native-resource telemetry — 2026-09-20

The standalone service host now selects a native resource adapter only when the
runtime reports Linux. Both its headless and browser-enabled compositions
supervise the adapter after the HTTP service, so service restart replaces the
sampler while a handled source failure cannot reset the store or listener. A
non-Linux host starts no substitute sampler and makes no inferred native-resource
claim.

At startup and every 30 seconds the production source reads only
`/proc/meminfo`, `/proc/self/status` and `/proc/loadavg`, admitting at most 65,536
bytes from each. It emits a sample only when system available-memory bytes, the
BEAM OS-process RSS bytes and one-minute load multiplied by 1,000 are all
nonnegative integers. Missing, malformed, oversized, raising or throwing source
input emits no partial value. The service contract admits the existing exact
measurement set under only the new `service` surface and existing
`linux_procfs` source; paths, PID, scope and credentials remain absent.

Tests exercise production source selection, exact parsing, every unavailable
class, invalid sampler configuration, source exception isolation, closed-event
retention and composed host supervision. The complete service gate passed 305
tests and two generated properties at 95.1% production line coverage. The
headless application-host gate passed 18 tests at 96.7%, and its browser-enabled
gate passed 29 tests at 96.0%. Compiler, unused-dependency, formatter, dependency
audit, strict Credo, ExDoc, Dialyzer, OpenAPI, archive, native CLI, licences and
the 533-file stack-language policy passed wherever configured. Headless Nerves
verification passed 8 tests and the kiosk composition passed 11 with warnings as
errors and formatter checks.

This is deterministic host-software evidence. Packaged Linux source-cohort
evidence is recorded below; an immutable ordinary-package release/container
sample, Darwin or mobile native-resource adapter, measured capacity budget and
physical-device acceptance remain separate gates.

### Packaged Linux ARM64 native-resource source proof — 2026-09-20

A focused Linux ARM64 run assembled the browser-enabled bundled release from
Tracker commit `3fb273c08d106bc6377688591aaefffb32e2c021` inside the existing local
Elixir 1.18.4 / OTP 27.3.4.15 builder. The builder is Linux ARM64 image
`sha256:c03a37c4fda289749dbdf74be3da3501c6151fff943192e7b58d0d03e0a25f9f`.
The release identified itself as `wotex_tracker 0.1.0` and ran with external
BEAM tools removed from `PATH`.

The black-box release probe signed into the packaged browser host and polled its
authenticated operational view. It required one `native.sample` containing all
three closed measurements (`system_available_memory_bytes`, `process_rss_bytes`
and `load_1m_milli`) plus exact `surface: service` and `source: linux_procfs`
metadata. That assertion passed together with the HTTP/OpenAPI/SSE consumer,
browser workflow, Property resume, immutable history, restart/idempotency,
SIGTERM active-stream shutdown, SIGKILL recovery, retained revocation, invalid
storage rejection and SQLite-full rollback checks. The result document SHA-256
is `7e6d8249ca3c1e04fd3c23a7c2e31c4b73c212315dd016df2c6792bf9349ba96`;
its complete result and provenance are retained in
`verification/linux-native-resource-source.json`. The exact temporary container
and build volume were removed after recording the result.

This focused proof used production path dependencies under `MIX_ENV=dev` in the
builder and did not run the release as the final non-root, read-only runtime
image. It therefore proves the packaged source cohort, not the immutable
ordinary-package cohort. The complete UI source qualifier was attempted first
and stopped in sibling WoTEx commit
`cd73c5493d3453ae9ecd203c63b589676c9b9fd6`: its own binding HTTP Dialyzer gate
reports unmatched `nil | pid()` returns at `test/support/fake_client.ex` lines
17 and 18. No receipt is promoted for that cohort until the upstream gate is
clean and the complete qualifier passes. Physical Linux/Pi behavior, capacity
budgets and Darwin/mobile adapters remain unqualified.
