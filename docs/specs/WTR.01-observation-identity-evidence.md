# WTR.01 Observation, identity and evidence model

## Status

Accepted target contract. No implementation claim.

## Observation envelope

Every physical input MUST first become a bounded immutable observation before decoding or identity claims. The envelope MUST distinguish capture facts from interpretations.

Required fields are conceptually:

```elixir
%Observation{
  id: explicit_id,
  observed_at: explicit_timestamp,
  ingress: declared_ingress,
  source: bounded_source_descriptor,
  addressing: bounded_addressing_metadata,
  payload: {:bytes, bounded_binary} | {:json, bounded_native_json},
  radio: %{rssi: optional, snr: optional, channel: optional},
  transport: bounded_transport_metadata,
  provenance: provenance_ref
}
```

The exact public type may evolve, but capture data and derived data MUST remain distinguishable.

This is a value sketch, not executable Elixir. IDs are nonempty bounded UTF-8 binaries; `observed_at` is a caller-supplied Unix timestamp in milliseconds. Device time is separately named metadata and never silently replaces receiver time. Runtime monotonic deadlines are different values under WTR.13. Ingress uses a fixed admitted vocabulary; extensions use bounded strings, never input-created atoms. A capture imported from BLE retains BLE as its physical ingress and records fixture/replay status in provenance.

Payload alternatives are explicit. Arbitrary binaries are not JSON strings. JSON values retain integers, floats, booleans, null, arrays and string-keyed objects without coercion. Wire formats use string keys; internal structs may use declared atom fields. Reject duplicate JSON members, atom/string key aliases, improper lists, structs inside JSON, invalid UTF-8 and non-JSON terms before decoding a profile. Use `Wotex.JSON.decode/2` for bytes declared to be JSON and `validate/2` for native JSON. A prior lossy map conversion cannot prove duplicate-free source JSON. Host binary export uses an explicitly versioned bytes envelope and canonical Base64, never `inspect/1` or implicit UTF-8 conversion.

## Identity is layered

Tracker MUST NOT equate a transient transport address with physical identity. Identity evidence may include:

- BLE address and address type;
- manufacturer data identifiers;
- advertised service UUIDs and service data;
- GATT Device Information values when an authorized active probe is permitted;
- IMEI or modem/device identifier from a qualified cellular protocol;
- LoRaWAN DevEUI/JoinEUI where legitimately available;
- protocol-level serial number;
- cryptographic device identity or signed attestation;
- operator enrollment association; and
- previously established continuity evidence.

A stable `Thing` identifier MUST be derived only by an explicit identity strategy. Raw MAC addresses, IMEIs, IMSIs, SIM identifiers, phone numbers, and LoRaWAN keys MUST NOT be exposed as public Thing IDs by default.

## Evidence records

Every derived claim MUST be traceable to evidence:

```elixir
%Evidence{
  kind: :fingerprint | :identity | :capability | :measurement | :position | :transport,
  claim: bounded_claim,
  source_observation_ids: [...],
  profile: {profile_id, profile_version},
  decoder: {decoder_id, decoder_version},
  confidence: :exact | :strong | :candidate | :unknown,
  reasons: [...]
}
```

`confidence` is a deterministic classification produced by declared matching rules. It is not an AI probability.

Profile-format confidence, device identity assurance, enrollment and authorization are independent facts. An exact advertisement-format match is not authenticated hardware identity or permission to publish/control a Thing. In particular, a format shared by several models does not prove one physical SKU. Matching and materialisation never grant authorization.

## Provenance requirements

Decoded values MUST retain enough provenance to answer:

- which physical observation produced this value;
- which profile and decoder version interpreted it;
- which identity evidence associated it with this Thing;
- whether the value came directly from the device or was derived/fused;
- which gateway/scanner/ingress observed it; and
- whether replay, staleness, or sequence anomalies were detected.

## Snapshot and identity consistency

One pipeline run consumes a single immutable catalogue snapshot. Resolution carries its identity and the exact selected profile/decoder revisions into decoding; materialisation also binds the model, capability mapping, identity strategy and deployment revisions. Fetching a mutable "latest" profile between stages is forbidden. Conflicting definitions under the same profile ID/version fail catalogue admission; externally stored revision labels must be bound to immutable content.

Every referenced observation and intermediate claim must resolve within the explicit evidence bundle or an identified immutable retained record. Duplicate IDs with unequal content, dangling references, evidence cycles, mixed device associations and mismatched revisions return typed errors. Reusing an observation ID is idempotent only when the entire admitted observation is type-strictly equal. Separate reception IDs preserve distinct gateway/time evidence even when a device measurement is deduplicated.

Where a digest identifies content, its versioned preimage must cover every interpretation-relevant field and referenced revision, including quality, units, identity association and deployment inputs for a materialised TD. Do not hash only the sensor value or drop unknown admitted fields. Compare canonical identity values with `===`/`!==`: `1` and `1.0` must not collide when canonical bytes distinguish them. Use upstream canonical JSON only for admitted native values and identify that encoding; it is not an RFC 8785 claim. A digest is a consistency check, not authentication.

The first identity strategy consumes an explicit caller-provided pseudonymous Thing ID plus association evidence; it creates no persistent association. Production enrollment later owns uniqueness and key custody. Unsalted hashes of enumerable MAC/IMEI values do not provide a private public identity. Association changes require explicit evidence and do not rewrite history. Raw-evidence retention may expire under privacy policy; preserve bounded lineage/tombstones and disclose that replay is unavailable rather than claiming retained bytes still exist.

## Unknown and ambiguous devices

An unmatched observation MUST remain representable as `unknown` evidence and MUST NOT be silently discarded solely because no profile exists.

If two eligible profiles meet the same highest confidence under WTR.02, automatic admission MUST stop with an ambiguous result. Candidate-only matches remain unknown with insufficient evidence. A UI or operator may inspect evidence and enroll a device, but that decision must be recorded as explicit operator evidence rather than rewritten as automatic detection.

## Bounds

Implementations MUST configure finite limits for advertisement size, network frame size, nested metadata, candidate profiles, evidence chain depth, probe count, observation retention, and decoder output size. Oversized or malformed inputs fail as typed errors before reaching profile-specific code where practical. WTR.13 sets the first-slice budgets and requires per-adapter lifecycle budgets before any live acquisition. Unknown observations obey the same retention and admission limits as known devices.
