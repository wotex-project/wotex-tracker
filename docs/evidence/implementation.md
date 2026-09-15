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
