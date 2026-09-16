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

## WTR.07 bundled releases and local Linux image — 2026-09-15

The immutable production cohort now assembles the standalone host with bundled
ERTS for Darwin ARM64 and Linux ARM64. Both retain normal package requirements
and the source lock; a temporary signed loopback registry supplies unpublished
sibling artifacts. The Linux builder pins Elixir 1.18.4 / OTP 27.3.4.15 and Hex
2.5.1 on a digest-pinned Debian Bookworm base. A separate runtime image includes
runtime libraries and Python, runs as UID/GID 10001, and contains no external
Elixir, Erlang, Mix or compiler. Release distribution is disabled. Runtime
license/notice files accompany the assembled release.

The independent Python/OpenAPI workflow runs against the actual bundled service.
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
line coverage and 5 Python CLI tests. The six clean production service consumers
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
coverage plus 5 Python CLI tests. The separate CLI process verifies the real HTTP
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
with 5 ExUnit tests, 98.3% coverage and 6 independent Python tests. The root's
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
