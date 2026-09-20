# WTR.09 Hardware qualification and vendor independence

## Status

This contract inherits WTR.12's independent completion axes and WTR.13's
greenfield Zig policy. Missing external prerequisites never block locally
executable implementation.

Accepted target contract. The Teltonika TAT140 is the baseline physical tracker
target. Documentation-fixture software profiles, an exact direct-endpoint SMS
plan, an honest Configurator/USB BLE-sensor manifest and deterministic local
peers exist for TAT140; ATC700 retains its comparison profile. No listed hardware
is qualified and no physical implementation claim follows.
Ruuvi RAWv2 is retained only as software regression data and is not a product,
purchase, hardware-test or qualification target.

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

## Baseline target and reference fixtures

### Teltonika TAT140 — required physical tracker

Purpose: rugged smart-bike/asset tracking with GNSS, long-range LTE Cat 1
delivery to an operator-controlled endpoint and documented BLE sensor support.
The exact Sweden/EU hardware variant, firmware, BLE mode, SIM and carrier MUST
be recorded. Qualification requires real GNSS/position, motion, battery, direct
Codec 8 Extended acknowledgement and selected BLE-sensor evidence with vendor
cloud services absent from the data path.

The manufacturer's current [general description](https://wiki.teltonika-gps.com/view/TAT140_General_description)
and [Bluetooth settings](https://wiki.teltonika-gps.com/view/TAT140_Bluetooth%C2%AE_settings)
describe LTE Cat 1/GNSS/Bluetooth and BLE sensor scanning. Those pages establish
a candidate capability, not qualification and not an iPhone provisioning
protocol. Phone-to-tracker provisioning MUST use an exact documented interface
proven on the selected TAT140 firmware, or the application must honestly present
the actual supported provisioning path.

The development adapter follows the latter path. It renders only the documented
SMS parameters 2001–2006 for APN and a TCP endpoint, with explicit SMS
authentication and 160-byte limits. Data Protocol and EYE Sensor slot-one setup
are emitted as named Teltonika Configurator selections over USB because the
current TAT140 pages do not publish a complete numeric SMS contract for those
fields. The manifest selects Codec 8 Extended, Sensors mode, the exact EYE Sensor
MAC, update frequency and lost-sensor alarm. It is not a wireless iPhone
provisioning claim.

### Ruuvi RAWv2 — software fixture only

The existing Ruuvi decoder vectors and finite simulator remain useful for pure
parser, discovery and failure-path regression. No RuuviTag will be acquired or
used for product hardware testing. Passing those fixtures proves nothing about
the selected TAT140, BLE radio operation or long-range tracking.

### Teltonika ATC700 — optional comparison profile

Purpose: compact rechargeable cellular/GNSS comparison profile. It is not
required for baseline product acceptance. BLE sensor-gateway capability MUST NOT
be claimed unless current device documentation and a real-device test prove it.

The current documentation fixture establishes only Codec 8 Extended framing,
the documented movement/battery IO mappings and configurability of a direct
operator-controlled TCP/UDP endpoint. Exact hardware/firmware, SIM/operator
operation, endpoint behavior and any BLE capability still require physical evidence.

### LoRaWAN target

No specific LoRaWAN tracker is blessed by this contract. A candidate must pass the same vendor-independence gate. LoRaWAN remains optional to the architecture.

## Sweden

The initial qualification region is Sweden/EU. Profiles must record the exact cellular model/band variant and LoRaWAN regional parameters rather than assuming a global SKU works locally. New designs should not depend on long-term 2G availability. LTE-M/NB-IoT/Cat-1-family support is qualified against actual Swedish operator/device combinations.

## Form factor

For portable/bicycle use, a reference target is a finished compact rugged enclosure comparable in intent to small commercial asset trackers. Development boards without a suitable enclosure may be used for protocol development but MUST NOT satisfy the portable-hardware qualification lane.

## Smart-bike and application coverage

Complete product acceptance MUST use the selected TAT140 configuration and cover
position, battery, movement, documented BLE-sensor behavior and the long-range
reporting/alert path. The companion also requires an exact supported local
provisioning/read path. Record whether that phone-facing path belongs to the
TAT140 or an explicitly associated component; the TAT140's ability to scan BLE
sensors does not by itself prove that an iPhone can provision it. Proximity alone
cannot associate a sensor with a bicycle. Manufacturer brochure claims, an
unavailable control or a development board do not satisfy required coverage.

Qualify the Pi 5 as a separate gateway/control-panel target under WTR.14, including
display/touch/storage and power interruption. Its boot proof does not establish
portable enclosure or bike power suitability. Qualify the iPhone and selected
BLE accessory/firmware under WTR.15, with native permissions, central role,
provisioning/read/write, lifecycle and reconnect evidence. A desktop scanner or
mobile peripheral advertisement does not establish those capabilities.

No component is forced to implement unsupported capabilities merely to complete
a matrix. Select or implement a suitable qualified path; missing required
hardware coverage leaves the product gate unpassed.

## Vendor lock

Mandatory vendor cloud, non-exportable tenant identity, cloud-only decoding, or inability to point the device/network path at operator infrastructure is a hard failure for the OSS reference profile.
