# WTR.03 Device profiles, decoders and protocol adapters

## Status

Accepted target contract. No implementation claim.

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
- `Decoder` — maps qualified bytes/messages to typed measurements/events;
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

## LoRaWAN

LoRaWAN is optional. A LoRaWAN profile MUST distinguish the end-device application payload from the network-server integration. AppSKey/NwkKey material belongs to credential custody, never Thing Descriptions, observations, logs, or fixtures.

## Decoder safety

Decoders MUST be pure or bounded with explicit input/output limits. They MUST reject truncated, oversized, unsupported-version, impossible-range, and checksum/authentication failures as typed errors. Unknown fields SHOULD be preserved as bounded opaque evidence when doing so is safe, rather than guessed.

## Vendor cloud prohibition

A vendor REST API is not a device protocol qualification merely because it exposes telemetry. A profile may document optional vendor-cloud interoperability, but support status requires a qualified operator-controlled path from physical device to Tracker.
