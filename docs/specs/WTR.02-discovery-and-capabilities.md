# WTR.02 Discovery, fingerprinting and capability resolution

## Status

This contract inherits WTR.12's independent completion axes and WTR.13's
greenfield Zig policy. Missing external prerequisites never block locally
executable implementation.

Implemented for bounded provider observations, closed declarative predicates,
immutable catalogues, deterministic unknown/ambiguous/resolved outcomes and
evidence-backed readable capabilities. Imported captures and the configured
cellular ingress exercise that boundary. An optional service owner now executes
only host-allowlisted, read-only BLE GATT probes through an explicit upstream
session after current `interact` authorization, with finite concurrency,
deadline and value bounds plus caller-loss cancellation. Profile-owned closed
probe contracts and `resolve_with_probe/4` now admit the exact private result and
recompute only its passive candidate as strengthened, rejected or unchanged.
An explicitly started passive scanner owner now pulls one bounded capture at a
time from a fixed host adapter, isolates initialization and reads behind finite
deadlines, and serializes authorized service admission with deterministic
retransmission reconciliation. A finite Ruuvi peer is available only in dev and
test builds; it proves the simulator evidence class without powering a radio or
claiming an OS scanner. Live BLE adapter integration and physical capability
qualification remain open. See the
[profile guide](../guides/profiles.md) and
[executed evidence](../evidence/implementation.md#deterministic-active-probe-re-resolution--2026-09-20).

## Pipeline

The target discovery pipeline is:

```text
scanner / ingress
      |
      v
bounded Observation
      |
      v
passive fingerprints
      |
      v
candidate profiles
      |
      +-- no candidate --> unknown observation
      |
      +-- ambiguous ----> explicit unresolved evidence
      |
      v
optional bounded active probe
      |
      v
profile resolution
      |
      v
decode + capability evidence
      |
      v
Thing Model selection
      |
      v
validated instance TD
```

## Discovery providers

Discovery is not synonymous with BLE. A provider MAY discover through BLE advertisements, BLE GATT, local IP mechanisms, a cellular listener, MQTT topic enrollment, LoRaWAN network-server events, serial/USB, imported captures, or another bounded source.

Providers own physical scanning/listening mechanics and return observations. They MUST NOT directly create canonical Things.

## BLE first proof

The first local scan PoC SHOULD use passive BLE because it demonstrates the desired user experience with minimal device cooperation:

1. scan advertisements;
2. preserve address type, advertisement bytes, manufacturer data, service UUIDs/service data, RSSI and scanner identity;
3. fingerprint without connecting when passive evidence is sufficient;
4. only perform GATT discovery when a profile declares a safe bounded probe and policy allows connection;
5. produce profile candidates with reasons; and
6. decode capabilities from the resolved profile.

BLE random/private addresses MUST NOT be assumed stable identity.

## Fingerprints

A fingerprint is a declarative predicate over bounded evidence, not arbitrary code by default. It may match exact manufacturer IDs, payload version bytes, service UUID sets, protocol framing, ports, message preambles, field constraints, or cryptographic markers.

Profiles SHOULD prefer the narrowest stable evidence available. Device names and RSSI alone are weak evidence and MUST NOT yield `:exact` identity/profile confidence.

The first resolver uses declarative, bounded predicates over an admitted catalogue. Confidence ordering is `:exact`, `:strong`, `:candidate`, `:unknown`. Only `:exact` and `:strong` matches are initially eligible; a single highest eligible profile resolves, none yields `:unknown`, and an equal highest eligible tie yields `:ambiguous`. Candidate-only matches yield `:unknown` with reason `:insufficient_evidence` and retained candidates. Explicit enrollment may supply additional evidence in a new resolution; it must not silently lower the threshold or turn profile confidence into authenticated identity. Catalogue enumeration order, decoder success and arbitrary profile names MUST NOT break a tie. Sort diagnostic candidates by bounded profile ID/version for stable output; this order conveys no preference. Reject duplicate/conflicting profile definitions and limit exhaustion instead of truncating candidates and accidentally resolving an ambiguous input.

First-slice predicates cannot invoke probes, evaluate source text, compile regexes supplied by devices, or choose callback modules from payloads. Callbacks are trusted caller configuration with explicit result validation, not a sandbox for untrusted code.

## Active probes

Active probing can alter device power use, privacy, connection state, or physical behavior. A probe MUST declare:

- required transport;
- read-only versus mutating behavior;
- timeout and byte bounds;
- required authorization;
- expected response shape;
- evidence it can strengthen or reject; and
- whether failure is informative or merely unavailable.

No active probe may be executed merely because an AI suggested it.

## Capabilities

Capabilities describe what the device/profile evidence proves, not everything a product brochure claims. Examples include:

- temperature, humidity, pressure, acceleration, movement, magnetic state;
- GNSS position, cell-derived position, Wi-Fi-derived position;
- battery voltage/percentage and charging state;
- tamper or enclosure state;
- local BLE interaction;
- LoRaWAN uplink/downlink;
- LTE-M, NB-IoT, LTE Cat-1/Cat-1 bis or other cellular transport;
- configurable reporting interval;
- alarm/event delivery;
- remote configuration or firmware action, when safely qualified.

Capabilities MUST distinguish observable/readable, configurable/writable, invokable, and event-producing behavior so later WoT affordances are not invented from a flat feature list.

Supported capability and current measurement availability are separate. A transient unavailable value does not by itself remove/recreate an affordance or imply a capability upgrade. A counter or repeated advertisement does not automatically establish an Event or a current moving/stationary state. Those interpretations require a specified rule and time/sequence evidence.

## Capability changes

Firmware versions may change wire formats and capabilities. Profile matching MUST permit version ranges or discriminators. A material firmware/protocol change produces new evidence and may select a new profile version; it MUST NOT silently reinterpret historical observations.
