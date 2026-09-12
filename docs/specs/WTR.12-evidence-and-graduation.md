# WTR.12 Executable evidence, fixtures and PoC graduation

## Status

Accepted target contract. No implementation claim.

## Evidence classes

Tracker distinguishes:

- `unit` — pure matching/decoder/materialisation/rule tests;
- `fixture` — captured protocol bytes/advertisements with provenance;
- `simulator` — deterministic protocol peer/device simulator;
- `integration` — real scanner/socket/broker/network-server integration;
- `hardware` — real qualified physical device;
- `interoperability` — interaction through WoTEx bindings/runtime/directory; and
- `field` — bounded real deployment evidence such as Sweden/EU868/cellular operator testing.

No README claim may promote a lower evidence class as if it were higher.

## Fixture provenance

Every non-synthetic capture fixture MUST record device model, protocol/firmware revision when available, capture method, redaction/transformation, expected decoder/profile revision and source/license/permission. Credentials and stable personal identifiers are removed or deterministically replaced.

## Required first PoC

The first complete acceptance path is:

```text
real RuuviTag advertisement
 -> BLE discovery observation
 -> deterministic Ruuvi profile resolution
 -> capability evidence
 -> decode temperature/humidity/pressure/motion/battery as supported by the qualified format
 -> materialise validated TD from a reusable Thing Model
 -> expose/consume through Wotex Runtime
 -> observe value through headless API/CLI
```

No AI and no vendor cloud may be required.

## Second acceptance path

A finished cellular tracker such as a qualified TAT140 target sends records directly to an operator-controlled listener:

```text
real tracker
 -> direct network ingress
 -> protocol identity/acknowledgement
 -> decoder/profile
 -> normalized position/battery/motion evidence
 -> same generic tracking Thing Model family
 -> validated TD
 -> WoT interface
```

This proves that BLE discovery is one discovery lane, not the architecture.

## Optional LoRaWAN path

A LoRaWAN hardware profile graduates only after direct control of LoRaWAN credentials/network-server integration and real EU868 hardware evidence. It should demonstrate transport policy/fallback but is not required for baseline Tracker viability.

## Negative tests

The suite MUST include malformed/truncated/oversized payloads, unknown versions, ambiguous fingerprints, BLE random-address changes, replay/duplicate records, impossible measurements/positions, stale timestamps, credential leakage checks, unauthorized active probes, unauthorized physical Actions and vendor-cloud-only profile rejection.

## Conformance language

Passing Tracker tests does not by itself establish W3C WoT conformance, Bluetooth qualification, LoRaWAN certification, cellular certification, regulatory approval or hardware safety certification. Such claims require their own evidence.

## Graduation

A profile graduates from `research` -> `fixture` -> `integration` -> `hardware-qualified` only when the catalogue's declared gates have executed evidence. Code merged without hardware evidence remains below `hardware-qualified`.
