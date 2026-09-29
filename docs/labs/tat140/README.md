# TAT140 qualification lab

Status: planned; the TAT140 and a supported EYE Sensor are not on the bench.
No physical TAT140 qualification run has been recorded.

## Purpose

Qualify a Teltonika TAT140 as the first finished Tracker hardware target using an operator-controlled data path.

Target path:

```text
TAT140
  -> LTE Cat 1
  -> operator-controlled TCP ingress
  -> IMEI admission
  -> Codec 8 Extended
  -> raw observation custody
  -> TAT140 profile/decoder
  -> movement / GNSS / battery evidence
  -> tracking Thing
  -> WoTEx Runtime / headless service
```

No vendor cloud is part of the required path.

## Runbook

- [Physical setup and first qualification run](setup.md)
- [Hardware evidence checklist](evidence-checklist.md)
- [Nano 33 IoT discovery fixtures](nano-fixtures.md)

## Required hardware

- TAT140 EU regional variant suitable for Sweden;
- Swedish data SIM;
- Raspberry Pi 3 Model B v1.2 is sufficient as the development/service host;
- reliable microSD/power/network;
- a supported Teltonika EYE Sensor for the complete baseline BLE-sensor gate;
- optional Nano 33 IoT BLE fixture for separate discovery experiments.

## Acceptance phases

### 0. Identity
- record exact order code/SKU;
- record firmware and configuration-tool revision;
- retain IMEI/ICCID privately;
- create pseudonymous public fixture identity.

### 1. Connectivity
- configure APN;
- configure operator-controlled host and TCP port;
- prove real mobile attach and TCP connection.

### 2. Protocol
- prove IMEI handshake;
- receive a real Codec 8 Extended frame;
- validate frame/CRC/record count;
- send correct acknowledgement;
- preserve sanitized golden fixture.

### 3. Semantics
- verify movement evidence;
- verify battery evidence supported by the actual unit/firmware;
- obtain a valid GNSS fix outdoors;
- materialize the expected tracking Thing.

### 4. Durability
- restart Tracker service;
- replay/retransmit;
- verify deduplication;
- break upstream reachability;
- restore connectivity;
- prove no invented delivery or location.

### 5. BLE sensor qualification
The first cellular, GNSS, movement and battery run can finish before this phase.
Complete baseline qualification also requires an EYE Sensor record through the
TAT140's supported sensor mode. Keep that path separate from Pi-direct BLE
discovery, and record the exact tracker and sensor firmware.

## Evidence

Every run records:
- hardware SKU;
- firmware;
- SIM/operator/APN class without credentials;
- Tracker/WoTEx commits;
- listener configuration digest;
- sanitized protocol fixture digest;
- expected and actual semantic values;
- restart/offline/replay outcomes;
- explicit limitations.

See the repository hardware qualification and security documents for redaction rules.
