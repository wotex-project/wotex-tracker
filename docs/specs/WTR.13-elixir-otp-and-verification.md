# WTR.13 Elixir/OTP implementation and verification floor

## Status

Implemented as the source/package verification floor for the root library,
service, shared UI and applicable hosts. The declared Elixir 1.18.4 / OTP
27.3.4.15 and Elixir 1.20.4 / OTP 29.0.4 lanes run their configured compiler,
test/coverage, analysis, documentation, dependency, archive, contract, licence
and language-policy gates as applicable. Each root, service and shared-UI
archive gate resolves its own project root and requires every regular packaged
source and private asset under `lib/` and `priv/`; adding a module, migration,
contract or static asset cannot rely on a hand-maintained sample list. This does
not claim every version allowed by Mix, every platform/toolchain, published
package availability or any physical hardware lane. See the
[executed evidence](../evidence/implementation.md#foundation--2026-09-15).

## Library application and ownership

Use a normal Mix library under `Wotex.Tracker`, with immutable structs, small
functions, pattern matching and guards. No application startup callback,
singleton, ambient application configuration, dynamic atom names, module-load
I/O or automatic adapter discovery. Configuration enters through explicit,
validated inputs; public functions have documentation and typespecs. Put one
module in each `.ex` file. Namespace Tracker modules without changing upstream
WoTEx namespaces.

Pure operations execute in the caller. Do not allocate a GenServer, Agent, ETS
table or task per value/profile to organize code. Use behaviours only for real
substitution seams; explicit values or functions suffice for the first clock,
catalogue and identity inputs. No generic plugin framework, macros/DSL compiler,
Python service, Rust helper, NIF or database is needed for the first decoder.

Repository implementation, verification and packaging use Elixir/Erlang or the
established native language of the owning platform. Prefer C, C++ or Rust for
native helpers and independent native consumers. Python is not admitted for
source, scripts, tests, generators, consumers, CLIs, build steps, runtime images
or verification dependencies. Existing Python surfaces are migration debt and
MUST be removed instead of extended. Independent consumers remain independent by
using only the public wire or package contract and by importing no production
domain modules; choosing a different language does not establish that boundary.

Future long-lived discovery/ingress components expose explicit `start_link/1`
or child-spec APIs. The caller chooses the supervisor, IDs, optional names,
restart strategy and configuration. Two differently configured instances must
coexist without global configuration changes or cross-talk. A library may own
resources acquired by that explicit instance; it never claims ownership of an
existing radio/service merely because it can discover it. Native protocol work
stays with its existing WoTEx owner and needs separate platform evidence.

The [library-design references](../provenance/primary-sources.md) explain this
boundary. It does not require reimplementing OTP services or removing legitimate
standard-library dependencies such as crypto. Reference host applications may
have their own startup callback; that callback is not part of the Tracker package.

## Planned runtime and dependencies

Phase 0 declares Elixir `~> 1.18`. Required initial verification lanes are
Elixir 1.18.4 / OTP 27.3.4.15 and Elixir 1.20.4 / OTP 29.0.4, recorded with exact
OS/architecture and dependencies. These are intended lanes until executed, not
a claim that every combination allowed by the Mix requirement has passed.
Only APIs available on the floor may enter the core. Optional adapters/hosts
record their own compatible runtime and native prerequisites; an optional
backend cannot silently raise the core floor.

Core requires `wotex`; use its TD/TM/JSON/DataSchema contracts. Test tools such
as StreamData are test-only; documentation/static-analysis tools do not become
runtime dependencies. Add runtime telemetry only with an implemented event
contract. Keep Runtime, bindings, concrete network clients, web servers, stores,
Nerves firmware configuration, Nx backends and Refpath in their owning optional
integration or host. Compile-time references must not require absent optional
modules. WTR.10 governs development path dependencies and artifact identity.

## First-slice admission limits

These are conservative package budgets, not measured performance claims or
radio-format maxima. Profile-specific limits may be stricter. Reject invalid,
duplicate or unknown options; never silently substitute a default for an invalid
supplied limit. Tests exercise limit minus one, limit, and limit plus one.

| Boundary | Default budget | Enforced before |
|---|---|---|
| Observation/profile/revision IDs | 256 UTF-8 bytes each, nonempty | identity lookup and diagnostics |
| Raw observation payload | 65,536 bytes | profile callbacks and payload parsing |
| Metadata or JSON payload, each | 65,536 source/string bytes; depth 16; 4,096 nodes; 256 entries per collection; 4,096 bytes per string/key | derived domain admission |
| Catalogue | 256 profiles; 32 predicates per profile; 256 returned candidates | evaluation/allocation; never truncate a tie |
| Decoder result/evidence bundle | 256 claims; 64 source references per claim; lineage depth 16 | materialisation and persistence |
| Aggregate admitted claim JSON | 65,536 string bytes; depth 16; 4,096 nodes | publication or state insertion |
| Materialisation | 64 affordances total; 8 Forms per affordance; 256 KiB source/string bytes; depth 32; 16,384 nodes | upstream TD construction |
| Public error projection | 32 details; 1,024 UTF-8 bytes per diagnostic string | logging or serialization |

The raw Ruuvi payload is exactly 24 bytes and does not inherit the general
64 KiB allowance. Catalogue/decoder outputs also obey recursive metadata/claim
budgets; counting top-level keys alone is insufficient. A native JSON byte
budget follows `Wotex.JSON.Limits` string-payload semantics; it is not a heap
limit or total wire-encoding length. Host encoders separately bound final wire
bytes, including escaped strings/Base64. Serialized output is never silently
truncated. A native input map has already been allocated by its caller; admission
bounds subsequent work, not memory allocated before the call.

Implement bounded traversal that stops on exhaustion. Avoid measuring an
unbounded enumerable with `Enum.count/1` or converting it to a list before
admission. No infinite/lazy provider stream is consumed by a pure constructor.
Check frame length before bit matching, nesting before deep parsing, and
collection/node limits during traversal. Exact profile errors and admission
phases remain documented alongside their regression tests.

## Error and callback contract

Expected boundary failures return `{:error, %Wotex.Tracker.Error{}}`, with a fixed
code/phase, bounded path and redacted details. Valid unknown/ambiguous resolutions
remain successful domain results under WTR.07. Keep malformed configuration,
unsupported capability, unavailable measurement, conflict and unknown physical
effect distinct. Never translate failure into an empty success value.

Validate options before calling `Keyword` functions and inputs before trusting a
struct tag. Validate callback return shapes and all provenance identities before
accepting success. Pure trusted callbacks may raise programming errors; do not
rescue the whole pipeline. If a live adapter promises to normalize callback
raises/exits, isolate that specific seam, release owned resources, return a
bounded callback-failure code, and test it. Never expose raw exception text or
credential-bearing terms. Caller code is trusted executable code, not sandboxed
by Elixir typespecs, process isolation or output limits.

## Live lifecycle prerequisite

Before any scanner/listener implementation, its owning adapter spec must fix
finite session count, in-flight request count, frame buffer, queue byte/count,
operation deadline, idle timeout, retention and cleanup budgets. No live adapter
is accepted with those quantities unspecified. Pull/credit-based intake or
explicit socket backpressure is preferable to unbounded `send`/`cast` traffic.
A sampled mailbox length is an overload signal, not a hard memory bound against
arbitrary senders. UDP/passive RF loss remains visible; it is not reliable delivery.

Track an instance/session generation and request identity. Monitor owners and
receivers; cancel timers and release only acquired resources on stop, failed
startup or owner loss. A stale timer/reply from an earlier generation cannot
change the next instance. Stop/cancel is bounded and idempotent. Do not rely
solely on `terminate/2`, which is not guaranteed after every crash or kill.
Any external child needs a qualified owner-loss strategy.

Use a caller-defined local monotonic deadline in milliseconds for operation
budgets and receiver Unix time for evidence. Pass the remaining budget through
each layer rather than restarting a relative timeout. Negative monotonic values
can be valid; expiry is determined by comparison with the same clock domain,
not by testing positivity. Never serialize monotonic deadlines for comparison
on another node or after restart. A timeout is not cancellation or remote
rollback; late acknowledgements and unknown effects follow WTR.06.

Acceptance includes two independent instances, failed startup, disconnect,
owner/receiver death, slow consumers, queue exhaustion, stale generation
messages, repeated cancellation and teardown. Runtime subscriptions retain the
upstream lifecycle rather than adding a second Tracker subscription engine.

## Performance and resource evidence

Use OTP processes for resource lifetime and concurrency. Connection/command
lifecycles may use `:gen_statem` when state-specific events and deadlines justify
it; deterministic decoding, geometry and rule transitions remain pure functions.
Socket active-once/credit or pull control must be tied to downstream capacity,
not an unbounded mailbox. Per-device ordering and cross-process store concurrency
must agree; one process per connection does not serialize a device reconnecting
through a second connection. Bound incomplete frames and expire abandoned sessions.

Use binary pattern matching for fixed frames, prepend/reverse accumulation,
maps for repeated identity lookups, and iodata at suitable output boundaries.
Avoid growing-left list append and indexed list scans in repeated work. Keep
one admitted native value across the pipeline instead of repeated JSON passes.
Carry bounded references rather than copying complete capture histories to
every process. Inspect retained sub-binaries and ETS copies before choosing a
copy/cache strategy. No global `persistent_term` catalogue or ETS cache without
a measured need and explicit update/ownership semantics.

Benchmark a suspected hot path before optimization with the same inputs,
runtime, warmup and concurrency. Keep setup outside the timed work and report
time distributions, input sizes and allocation method separately from peak RSS.
Correctness tests assert outcomes and bounds, never flaky timing speedups.

## Verification and packaging

Every implemented capability has observable acceptance tests; every reproduced
bug fix includes a regression. Generators include valid zeros, false, missing
values, Unicode, escaped keys, counter boundaries and mixed availability. Use
independent protocol expectations as well as properties; round trips alone can
preserve a shared bug. Tests should fail when decoding, identity coverage,
ambiguity handling or atomic publication is deliberately broken.

The complete local gate must explicitly run formatting, warnings-as-errors
compilation, the full ExUnit/property/doctest suite, strict Credo, Dialyzer,
documentation checks, dependency/security/license checks and at least 95% line
coverage for production code. Do not inherit a sibling's disabled tools and
claim they ran. `mix check --no-retry` runs the full configured gate once that
gate exists; it must not resume only previously failed tools. Never weaken a
threshold, add a hiding suppression, or change constraints just to pass.

Build and inspect the actual Hex archive, including required models, notices
and documentation while excluding secrets, local evidence workspaces and build
state. In isolated consumers test locked, freshly resolved and selected compatible
minimum dependency sets with unchanged repository locks. Test optional integrations
both absent and explicitly present, including production compilation without
development path switches. Record unsatisfied releases or incompatible combinations
honestly; no resolver override counts as compatibility. Build is not publication.
All consumer orchestration and contract generation obey the repository language
policy and the full gate rejects tracked Python files or Python interpreter
requirements.

WTR.12 and the implementation plan distinguish spec checks, software acceptance,
host integration and hardware qualification. Do not mark an unimplemented
capability complete because this document or a static source scan passes.

Service-only, UI-enabled, Pi and mobile projects each run their applicable full
gate with an explicit runtime/native-toolchain manifest. Shared service/UI
packages follow root library ownership rules and are tested with independent
instances and absent host modules. A newer host runtime cannot silently alter
the core's supported lanes. CI definitions or counts of tests are not evidence
that a physical plugin, browser, display or radio worked.

Before declaring application readiness, run WTR.07/14/15/16 observable behavior
and integrated failure scenarios on the actual packaged hosts. Measure cold/warm
startup, input-to-render latency, query/stream load, peak RSS and device energy
under comparable conditions; allocation is a separate measurement. Preserve
full test selection, coverage, strict analysis and security checks. No disabled
dependency capability or missing account changes a required product gate to optional.
