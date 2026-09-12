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
  ingress: :ble | :tcp | :udp | :mqtt | :http | :lorawan | :fixture | atom(),
  source: bounded_source_descriptor,
  addressing: bounded_addressing_metadata,
  payload: bounded_bytes_or_value,
  radio: %{rssi: optional, snr: optional, channel: optional},
  transport: bounded_transport_metadata,
  provenance: provenance_ref
}
```

The exact public type may evolve, but capture data and derived data MUST remain distinguishable.

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

## Provenance requirements

Decoded values MUST retain enough provenance to answer:

- which physical observation produced this value;
- which profile and decoder version interpreted it;
- which identity evidence associated it with this Thing;
- whether the value came directly from the device or was derived/fused;
- which gateway/scanner/ingress observed it; and
- whether replay, staleness, or sequence anomalies were detected.

## Unknown and ambiguous devices

An unmatched observation MUST remain representable as `unknown` evidence and MUST NOT be silently discarded solely because no profile exists.

If two profiles meet the same highest confidence and cannot be deterministically disambiguated, automatic admission MUST stop with an ambiguous result. A UI or operator may inspect evidence and enroll a device, but that decision must be recorded as explicit operator evidence rather than rewritten as automatic detection.

## Bounds

Implementations MUST configure finite limits for advertisement size, network frame size, nested metadata, candidate profiles, evidence chain depth, probe count, observation retention, and decoder output size. Oversized or malformed inputs fail as typed errors before reaching profile-specific code where practical.
