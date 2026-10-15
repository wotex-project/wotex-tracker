---
title: "Portable Decoder Artifacts and Evidence-Preserving Replacement"
type: research
status: reconciled
terminal_state: bounded_validation
version: "0.1.1"
created: "2026-10-03"
source_revision: "5913f2175e4b51080e3faf6fbab67fbd92957054"
source_commit: "b9756fef9a5a3cf461cdf34f38ec93c9c899d403"
---

# Portable Decoder Artifacts and Evidence-Preserving Replacement

## Reconciliation on 2026-10-10

The original 2026-10-03 memo is retained below. Its bounded-validation decision
and promotion conditions are now explicit in [WTR.03](../specs/WTR.03-device-profiles-and-adapters.md).
Source review of `Wotex.Tracker.Decoder.run/5` confirms an explicitly supplied
trusted callback with exact revision matching and resolution/output validation;
it establishes no executable artifact installation or replacement capability.
The proposed experiments remain unexecuted. Existing product delivery and
qualification obligations remain governed by [WTR.12](../specs/WTR.12-evidence-and-graduation.md).

## Decision

Qualify **decoder and profile artifacts** as a bounded independent-delivery surface. Keep observation admission, catalogue resolution, Thing identity, tracking state, service authorization and physical Actions under their existing owners. Do not convert the entire Tracker product or all WoTEx transports into generic plugins.

The best initial experiment is a deterministic decoder supplied independently of the service release, with no network, filesystem, credential or state authority. Prefer a declarative mapping when the existing mapping language can express the change. A component or isolated native helper is justified only by a real decoder need and measured benefit.

The repository's native-language policy remains in force: official host tooling uses Elixir/Erlang and new bounded native work prefers Zig. This proposal does not add Python or select a new language runtime. It does not require a dependency on an external orchestration platform.

## Evidence and actual opportunity

The audit uses `5913f2175e4b51080e3faf6fbab67fbd92957054`. Reviewed sources: repository contract, README through hardware/host architecture, and the complete declarative profile guide [S1–S3]. These establish a concrete interpretation boundary; no current hot-install decoder implementation or executed portability benchmark is claimed.

The documented pipeline already binds observations to catalogue, profile, decoder and mapping revisions. `wtr.profile.v2` includes interpretation-relevant provenance; decoder references are inert strings. `Catalogue.new/2` produces an immutable sorted snapshot and rejects duplicate ID/version pairs. Resolution considers the complete bounded population, preserves ties as ambiguous and unknown evidence as unknown [S3].

This is stronger starting evidence than “the repository has packages.” Independent decoder distribution could avoid rebuilding the service for new formats while retaining replayable interpretation. It must not weaken the existing rule that profile matching neither executes a decoder nor establishes physical identity.

The README also documents independent service, LiveView, Pi 5, iPhone and Zig consumers. Their existence is architectural evidence, not a fresh confirmation of every stated test result or physical qualification [S2].

## Target boundary

```text
immutable observation + exact catalogue
  -> deterministic profile resolution
  -> admitted decoder artifact and exact mapping
  -> bounded interpretation evidence
  -> existing materialisation and service actions
```

The decoder consumes the same normalized bytes/metadata for each runtime. It returns typed measurements, recognized/unknown fields, diagnostics and evidence references. It cannot enroll a Thing, grant a capability, publish an authorized TD or mutate tracking history directly.

Proposed installation metadata includes implementation digest, decoder ID/revision, supported input and result schema digests, target/runtime profile, limits and conformance suite identity. These are proposed fields, not an existing schema. Keep metadata validation non-executing and bounded. No strings become dynamically selected BEAM modules or atoms.

The profile/candidate reference is pinned before invocation. Reject a different artifact under the same nominal decoder revision rather than accepting “latest.” Preserve the old executable or a reproducible equivalent for authorized replay.

## Data, component and native alternatives

| Alternative | Use | Rejection condition |
|---|---|---|
| Existing bounded mapping | First choice for expressible transformations | Requires unsafe evaluation or cannot represent required semantics |
| Pure component decoder | Candidate for portable custom computation | Required toolchain/host features or interruption cannot be qualified |
| Isolated Zig/native helper | Candidate where platform/library support requires it | Closure, target or resource isolation cannot be established |
| In-VM arbitrary BEAM loader | Not the public untrusted decoder boundary | Shared VM/module/atom authority undermines containment |
| Remote decoder service | Not the default | Adds connectivity and location-data disclosure without a demonstrated requirement |

WIT can describe an interface but cannot prove its output is a correct device interpretation [E1]. A raw-Wasm decoder can remain valid if it satisfies a declared bounded contract; standardizing on Component Model is not worth changing semantics or adding unsuitable embedded dependencies. Select the runtime using real fixtures, not language branding.

## Revision and replay semantics

Replacing a decoder affects future admitted interpretations. It cannot silently rewrite historical trips, geofences, identity or previously accepted measurements. Historical reprocessing creates a new interpretation revision linked to the original observation and records which downstream projections changed.

A profile update and decoder update are a joint compatibility decision. A matching decoder name does not qualify changed predicates, units, scaling, byte order or capability mapping. Publish a semantic diff and retain conformance for the exact pair.

A stream/batch invocation pins its implementation for its lifetime. On replacement, new work selects the new admitted cohort while existing work drains or is explicitly canceled. If service state changes during preparation, reject stale admission rather than binding old evidence to new state.

## Active probes and physical Actions stay separate

The existing guide describes an optional active GATT probe owner with immutable plans, predefined targets, authorization before worker execution and no bearer credential passed to the adapter. The adapter receives a host-owned BLE session; it does not select, pair, retry or close arbitrary peers [S3].

A decoder artifact must not acquire probe authority by returning a request. It can propose missing evidence; the existing probe admission path independently decides whether to obtain it. Matching a probe is still not enrollment or authorization.

Physical command success cannot be inferred from a decoded report, transport ACK or absence of error. The new artifact profile is read/interpretation-only until an independent effect contract is deliberately designed and physically qualified.

## Security and operations

Raw payloads and location traces are sensitive even without command authority. Give decoders the minimum required observation, not complete service history or device credentials. Deny network and filesystem imports. Keep logs bounded and redact private identifiers and payloads.

Apply independent limits to parsing, compilation, input/output, memory, execution, instances and queues. Killing an Erlang waiter is not proof that a native computation ended. A process runner must observe actual termination and cleanup; unsupported target isolation refuses rather than falling back to privileged execution [E2].

Use exact executable/dependency closure and locally available verification material. Component bytes, native binary, profile data and map packs have different content identities. An OCI layout may transport executable closure [E3]; it need not become mandatory for small profile documents or replace existing service/map-pack contracts.

An offline Pi must run installed qualified decoders without a registry. Firmware rollback does not restore revoked trust or overwrite historical decoder evidence. iPhone and browser clients consume service semantics; they do not automatically need to execute every decoder locally. An independent Zig client remains valuable protocol evidence without importing production domain modules.

## Work and qualification gates

P0: trace one shipped decoder's implementation and registry lookup from resolution to materialisation; freeze native fixtures and error behavior. The present document identifies the seam but does not substitute for that code audit.

P1: build one alternative bounded implementation and one declarative profile update outside the service source tree. Run the same complete fixtures against both without physical devices or paid endpoints.

P2: connect artifact installation to exact catalogue/decoder identity, retained replay and service lifecycle. Qualify actual Pi 5 and other intended hosts separately; an aarch64 build is not a physical deployment proof.

| Gate | Owner | Acceptance / falsifier |
|---|---|---|
| ENG-REFERENCE | Decoder owner | Exact input/result/refusal fixtures established from the owning contract, not only duplicated production code |
| ENG-PARITY | Decoder + materialisation | Native and artifact outputs agree on units, unknown fields, errors and provenance; mismatch blocks admission |
| ENG-NO-AUTHORITY | Runtime host | Decoder cannot perform I/O, choose a probe target, enroll or write service state |
| ACT-RESOLUTION | Profile/catalogue owner | Ambiguous ties remain ambiguous; successful decoding cannot change candidate selection retrospectively |
| ACT-REPLACEMENT | Service owner | In-flight work retains the old pair; stale configuration refuses; old receipts retain historical meaning |
| ACT-REPLAY | Evidence owner | Reprocessing creates new interpretation lineage rather than mutating original evidence |
| ACT-PROBE | Probe owner | Artifact output alone cannot initiate GATT work or widen active-probe scope |
| ACT-HOST | Host owners | Offline operation, bounded memory, timeout and process cleanup observed on declared targets |
| ACT-VALUE | Maintainer/consumer | A real added decoder requires no service rebuild; measured costs stay within a preregistered host budget |

Security failures block the profile independently of performance. No new infrastructure spend, dependency installation or physical dispatch is authorized. All experiments remain planned; no new acceptance numbers are claimed.

## Sources and promotion

- S1: [Repository contract](https://github.com/wotex-project/wotex-tracker/blob/main/AGENTS.md).
- S2: [README](../../README.md), evidence pipeline and host distinctions.
- S3: [Declarative profiles and resolution](../guides/profiles.md), including active probe boundary.
- Owner destinations: [specification index](../specs/WTR-index.md), [materialisation](../guides/materialisation.md), [service contract](../contracts/service-v1.md), [hardware qualification](../specs/WTR.09-hardware-qualification.md), [evidence policy](../specs/WTR.12-evidence-and-graduation.md).
- E1: [WIT design](https://component-model.bytecodealliance.org/design/wit.html).
- E2: [OTP ports](https://www.erlang.org/doc/system/ports.html).
- E3: [OCI manifest v1.1.1](https://github.com/opencontainers/image-spec/blob/v1.1.1/manifest.md).

The shared pattern is immutable interpretation plus owner-controlled admission, not a compulsory shared runtime. If the existing declarative mapping covers the required extension, deliver data and keep executable installation out of scope. Producer/consumer conformance must precede any normative promotion.
