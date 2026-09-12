# WTR.09 Hardware qualification and vendor independence

## Status

Accepted target contract. No implementation claim.

## Purpose

Tracker is multi-hardware by design. Hardware support is evidence-based and must never become an implicit endorsement of a vendor ecosystem.

## Qualification gate

A device/profile may be called `qualified` only when evidence proves:

1. a finished physical device or reproducible open-hardware target exists;
2. the relevant protocol/payload is documented or independently reproducible under a compatible legal/technical basis;
3. telemetry can reach infrastructure controlled by the operator without mandatory vendor SaaS;
4. required credentials/keys/SIM/eSIM can be controlled by the operator;
5. provisioning and reset/recovery paths are documented;
6. protocol/version identity can be bounded sufficiently for deterministic decoding;
7. representative real-device captures pass fixtures and live integration tests; and
8. security/privacy limitations are documented.

If any mandatory cloud independence claim cannot be verified, status is `research`, not `qualified`.

## Hardware matrix fields

Qualification records SHOULD include dimensions, mass, enclosure/IP/impact rating, power source, operating temperature, BLE capability, GNSS/positioning, LoRaWAN region/support, cellular bearers/bands, SIM/eSIM form, protocol openness, operator-controlled endpoint support, provisioning method, firmware/version evidence, Swedish network suitability, source URLs/revisions and test evidence.

## Initial targets

### RuuviTag

Purpose: passive BLE discovery/capability proof. Qualification requires an openly documented advertisement format and direct local scanning with no cloud dependency.

### Teltonika TAT140

Purpose: rugged cellular asset-tracker ingress proof. Qualification requires direct configuration to an operator-controlled endpoint and documented AVL codec behavior. Cloud management services must remain optional.

### Teltonika ATC700

Purpose: compact rechargeable cellular/GNSS tracker profile and comparison target. BLE sensor-gateway capability MUST NOT be claimed unless current device documentation and a real-device test prove it.

### LoRaWAN target

No specific LoRaWAN tracker is blessed by this contract. A candidate must pass the same vendor-independence gate. LoRaWAN remains optional to the architecture.

## Sweden

The initial qualification region is Sweden/EU. Profiles must record the exact cellular model/band variant and LoRaWAN regional parameters rather than assuming a global SKU works locally. New designs should not depend on long-term 2G availability. LTE-M/NB-IoT/Cat-1-family support is qualified against actual Swedish operator/device combinations.

## Form factor

For portable/bicycle use, a reference target is a finished compact rugged enclosure comparable in intent to small commercial asset trackers. Development boards without a suitable enclosure may be used for protocol development but MUST NOT satisfy the portable-hardware qualification lane.

## Vendor lock

Mandatory vendor cloud, non-exportable tenant identity, cloud-only decoding, or inability to point the device/network path at operator infrastructure is a hard failure for the OSS reference profile.
