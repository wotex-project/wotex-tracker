# WTR.03 Device profiles, decoders and protocol adapters

## Status

This contract inherits WTR.12's independent completion axes and WTR.13's
greenfield Zig policy. Missing external prerequisites never block locally
executable implementation.

Accepted target contract. The pure library implements immutable profile and
catalogue values, deterministic resolution and a bounded trusted-decoder seam for
measurements, positions and identity evidence. Ruuvi RAWv2 remains reference
fixture coverage only and is not a physical qualification target. A pure bounded Codec 8 Extended TCP
framer now validates the manufacturer documentation vector, arbitrary split and
coalesced frames, record/IO counts and CRC while preserving unknown IO bytes.
The pure TCP session seam also bounds split/coalesced 15-digit IMEI negotiation,
keyed private identity lookup and commit-dependent ACK-or-close decisions. It is
paired with an explicitly started service bridge that revalidates frames,
serializes configured keyed-device admission and reconciles deterministic
operation receipts before returning an ACK disposition. An explicitly started,
finite TCP listener now enforces login/frame deadlines and is exercised by an
independent Erlang peer across every fixture split. A documentation-qualified
TAT140 and ATC700 profiles now share a closed record engine while retaining
distinct immutable revisions. Both preserve multi-record messages while mapping
AVL 240 movement, AVL 67 battery voltage and valid GNSS fixes; ATC700 also maps
its documented AVL 113 battery level. Cellular admission now
binds an optional configured profile ID into the durable raw observation. The
record-aware import retains exact per-record evidence and the service atomically
persists its ordered public projections and private bundle. The generic cellular
Thing Model revisions materialise position, motion and battery-voltage
capabilities plus ATC700 battery level. Atomic ingress receipts now identify every record index with a
stable derived operation identity and the accepted, duplicate, rejected or
unknown frame outcome; partial batch admission is not implied by the count ACK.
The standalone host can select that fixed packaged contract and
supervise a separately private, finite cellular listener whose device bearers
are checked against configured scope authority. The optional service active-probe
owner reconciles every enabled host plan with its profile-owned probe contract,
then binds that revision to one host-allowlisted, read-only GATT target and
delegates the byte read to an explicitly supplied `Wotex.BLE` session without
owning or selecting the peer. The pure resolver admits canonical results and
recomputes only nominated passive candidates. Live passive discovery,
operator-network qualification, LoRaWAN and physical lifecycle acceptance remain
unfinished.

## Device profile

A device profile is a versioned, reviewable contract connecting physical evidence to semantic capability. It SHOULD be data-driven where possible and code-backed only where bounded decoding/probing requires it.

A profile conceptually declares:

```elixir
%DeviceProfile{
  id: "ruuvi.ruuvitag.rawv2",
  version: "1.0.0",
  fingerprints: [...],
  identity_strategy: ...,
  decoders: [...],
  probes: [...],
  capabilities: [...],
  thing_model: "urn:wotex:tm:tracker:environmental-sensor:v1",
  transports: [...],
  security: ...,
  source_provenance: [...],
  qualification: ...
}
```

## Adapter boundary

Adapters translate a qualified external protocol into observations and interaction requests. They MUST NOT redefine generic WoT runtime behavior.

Target behaviours SHOULD separate:

- `DiscoveryProvider` — obtains bounded observations;
- `Fingerprint` — scores/classifies candidates deterministically;
- `Probe` — performs an explicitly authorized bounded query;
- `Decoder` — maps qualified bytes/messages to typed measurements, positions or events;
- `IdentityStrategy` — derives private stable device identity and public Thing identity;
- `InteractionAdapter` — executes profile-specific operations not already covered by a generic WoT binding; and
- `ProfileRegistry` — supplies immutable/versioned profiles to a resolution run.

The exact module names are not fixed by this document.

## Generic protocol graduation

Tracker MAY contain the vertical observation adapter needed for its PoC. Generic BLE/GATT values, protocol execution and WoT Form mapping belong to the existing `wotex_ble` package. Its current `discover/2` discovers characteristics on a selected GATT session; it is not a passive advertisement scanner. The live provider MUST verify an appropriate public scanning surface before using it. Missing reusable scanning support belongs in a reviewed upstream contract; imported captures keep the pure milestone independent of that work.

The same rule applies to any future generic LoRaWAN network-server integration. LoRaWAN device profiles and tracking payload decoders may remain here; a reusable WoT binding or discovery provider should graduate upstream.

## Cellular trackers

A cellular tracker that opens TCP/UDP/MQTT/HTTP directly to operator infrastructure is modeled as an ingress protocol plus device profile. Cellular radio technology itself is not a WoT binding.

For protocols such as Teltonika AVL, a profile/adapter MUST preserve protocol identifiers, codec/version, record sequence where available, IO element provenance, acknowledgement semantics, and connection identity evidence before mapping records to tracking capabilities.

Framing, session negotiation, pure decoding, authorized admission and outbound
acknowledgement are separate responsibilities. Login, heartbeat and command
responses can be valid messages with no position; one frame can contain multiple
records. An empty measurement list alone cannot represent all of these outcomes.
Use explicit message variants and return bounded incomplete-frame state, decoded
records or a typed rejection. Never treat a socket read as one complete frame.

The selected adapter MUST specify length/count/checksum coverage, byte ordering,
supported codec/IO revisions, sequence scope, reconnect behavior and the exact
acknowledgement for accepted/rejected/duplicate records. Per-device admission is
serialized through explicit ownership or store concurrency control; transport
sessions cannot race canonical state updates. ACK encoding follows WTR.06 commit
outcomes and the physical protocol, not an assumption that decoding means storage.

Before hardware acceptance, exercise independent byte fixtures and a software
peer with every frame split boundary, concatenated frames, incomplete EOF,
oversized declared lengths, unknown IO elements, mixed record validity, checksum
failure, login without telemetry and command responses. Test connection loss
before and after commit, retransmission and bounded session/buffer exhaustion.
Protocol documentation and device/firmware evidence must agree; another decoder
is not the authority for undocumented behavior.

## LoRaWAN

LoRaWAN is optional. A LoRaWAN profile MUST distinguish the end-device application payload from the network-server integration. AppSKey/NwkKey material belongs to credential custody, never Thing Descriptions, observations, logs, or fixtures.

## Decoder safety

First-slice decoders MUST be pure with explicit input/output limits. Framing, unsupported-version and required checksum/authentication failures return typed errors; a checksum is not authentication. Known missing-value sentinels are valid field states, not malformed frames. Out-of-range interpretations must not become valid measurements: preserve bounded raw evidence and report the field's quality/reason, rejecting the frame only when its declared format requires that. Unknown fields may be retained as bounded opaque evidence without inventing their meaning. Unexpected callback returns fail explicitly; programming errors are not swallowed by a broad pipeline rescue.

Position-capable decoder output is a bounded list of complete normalized claims,
not a detached coordinate. Admission binds every position to its receiver
observation, immutable catalogue snapshot and exact profile/decoder revisions.
Duplicate or malformed claims and mismatched receiver lineage fail the whole
decoder output explicitly. Valid protocol messages without a position retain an
empty position list.

Decoded output carries a declared measurement kind, native value when available, unit, availability/quality, and complete evidence references. Missing, false and zero are distinct. Never emit NaN, a string pretending to be a number, or an invented zero as a missing measurement. A null wire value is valid only when the affordance schema admits it; otherwise the host reports unavailable state using its declared error contract.

## First decoder acceptance

Ruuvi RAWv2 uses the exact manufacturer-data slice defined by the [source record](../provenance/primary-sources.md), separating the company identifier from its 24-byte format-5 payload. Match length/version before bit-syntax decoding; test both manufacturer-byte ordering and signed field ordering. Required cases include ordinary, minimum, maximum, unavailable and mixed-availability vectors; independent battery/TX sentinels; truncated/extra bytes; unsupported versions; and counter rollover. Preserve anomalous humidity as suspect evidence. Do not infer battery percentage, authenticated identity, movement state or a movement event from this frame alone. Record exact units and source-derived expectations with the fixtures, separately from any real-device qualification.

## Vendor cloud prohibition

A vendor REST API is not a device protocol qualification merely because it exposes telemetry. A profile may document optional vendor-cloud interoperability, but support status requires a qualified operator-controlled path from physical device to Tracker.
