# WoTEx Tracker physical hardware lab

Status: operator build and hardware-qualification guide. Software support is not physical-device qualification.

## Goal

Qualify the real product path with a finished Teltonika TAT140 while reusing the existing bench for gateway, BLE and synthetic-device evidence.

```text
TAT140
 -> LTE Cat 1
 -> operator-controlled TCP endpoint
 -> Tracker IMEI + Codec 8 Extended ingress
 -> raw observation custody
 -> profile/decoder
 -> evidence-backed Thing
 -> retained state/history

open BLE sensor
 -> Pi 3 / BlueZ
 -> Tracker BLE boundary
 -> evidence-backed Thing
```

The TAT140 is the tracker under qualification. Arduino boards are test peers/sensors, not substitutes.

## Available bench hardware

| Hardware | Tracker-lab use |
| --- | --- |
| Raspberry Pi 3-class Model B in case | Local Tracker service/gateway, BlueZ scanner, TCP endpoint on LAN/VPN side, SQLite and evidence capture. Exact B/B+ revision needs PCB confirmation. |
| 2 x Arduino Nano 33 IoT | Open BLE/Wi-Fi sensor/tag simulators; onboard IMU; deterministic owner-presence/sensor fixtures. |
| Arduino Uno R3 | USB serial/GPIO fault and sensor simulator. |
| Shelly Motion 2 | Finished Wi-Fi motion source for cross-transport capability tests after local API/firmware verification. |
| ESP8266 ESP-01S + programming hardware | Optional tiny Wi-Fi peer. |
| Bagged sensor/PIR-style modules | Physical fixtures after exact identification. |
| Breadboard/electronics kit | Wiring, buttons, LEDs and passive components. |
| Delock smart plug | Generic WoT control only after exact model/local protocol verification. |
| USB cables/adapters/power | Bench support after voltage/function verification. |

The Pi 3 is enough for the first Tracker gateway/hardware qualification. Pi 5 is a product/performance target, not a prerequisite for the TAT140 wire lane.

## Missing hardware

### Required for the first real tracker lane

1. Teltonika TAT140 EU variant suitable for Swedish LTE bands.
2. Micro-SIM/data subscription with the required APN and outbound data.
3. Operator-controlled reachable TCP endpoint. The Pi can terminate it only when the network/VPN topology securely makes it reachable.
4. Known-good Pi microSD and correctly rated supply if the photographed ones cannot be verified.
5. Multimeter before mixed-voltage bench wiring.

### Useful later

- logic analyzer for serial/SPI/I2C fixtures;
- second openly documented BLE sensor/tag;
- LoRaWAN gateway/radio only when a LoRa profile is selected;
- Pi 5 for Pi-5-specific control-panel/product acceptance.

## TAT140 identity gate

Record exact order code/module variant, firmware and Configurator revision. Keep IMEI private.

The target path must use direct operator-controlled server configuration. Vendor cloud/FOTA tooling may be optional but is not part of the required telemetry path.

## Pi 3 gateway setup

### Stage A: Linux first

1. Record exact Pi model/revision from PCB.
2. Install current supported 64-bit Raspberry Pi OS Lite.
3. Prefer Ethernet.
4. Configure SSH keys and hostname such as `wotex-tracker-gw1`.
5. Install the exact Erlang/OTP and Elixir cohort required by this repository and selected WoTEx packages.
6. Pin exact Tracker and WoTEx revisions.
7. Run the complete software gate before hardware ingress.
8. Configure a private keyed IMEI mapping for the TAT140.
9. Bind the cellular listener only on the intended interface/port.
10. Put SQLite data on durable storage and rotate logs.
11. Keep raw evidence private and expose pseudonymous Thing identity publicly.

### Stage B: BLE gateway

Verify Linux/BlueZ independently, then use WoTEx BLE and Tracker's explicitly started BLE boundary. Nano #1 is the controlled BLE target.

Admission remains observation -> fingerprint/profile -> evidence -> enrollment/materialisation. A scan result is not automatically a Thing.

### Stage C: embedded host

Only after Linux evidence passes should Nerves be attempted. The Tracker product plan names Pi 5 for final control-panel acceptance. Pi 3 can become a separate development/edge target if intentionally specified, but it cannot satisfy a Pi 5 gate.

## Configure TAT140 for direct qualification

1. Follow the manufacturer opening/SIM procedure.
2. With device off, insert the Micro-SIM.
3. Disable SIM PIN unless the selected configuration explicitly handles it.
4. Enable the device and record exact hardware/firmware identity.
5. Configure APN.
6. Set **your** DNS/IP and listener port.
7. Select TCP for the first lane.
8. Select Codec 8 Extended.
9. Use a short lab reporting interval and movement reporting while bench testing.
10. Keep optional vendor cloud/FOTA out of the required data path.
11. Restore a battery-sensible reporting policy after the lab.

## Network topology

Do not blindly port-forward a development Pi to the Internet.

Preferred:
```text
TAT140 -> LTE -> operator-controlled public ingress/VPN -> Tracker service
```

A direct public Pi listener is acceptable only with deliberate firewalling, narrow protocol admission, current OS, no exposed management ports and an understood residential/CGNAT topology.

The Tracker listener must enforce the implemented finite connection/frame/deadline budgets and keyed IMEI admission.

## Nano 33 IoT fixtures

### Soldering

The boxes photographed say **with headers**. Inspect the actual boards first. If factory headers exist, do not re-solder them.

If headerless, use a breadboard to hold straight 2.54 mm headers, tack corners, align, finish joints, inspect/continuity-test, then boot by USB with nothing attached. Nano 33 IoT is a 3.3 V GPIO device.

### Nano #1: BLE passive/active fixture

Use its IMU to advertise a versioned synthetic motion payload and expose a tiny GATT service. This gives deterministic positive/negative profile fixtures and exercises passive discovery plus authorized probe behavior.

### Nano #2: owner-presence / secondary sensor fixture

Use a distinct identity/protocol revision. It can simulate owner presence, battery, motion or a passive asset sensor. Deliberately rotate BLE private addresses in a test firmware mode so Tracker proves it does not equate address with durable identity.

## Uno and bagged sensors

Start Uno through USB serial; do not connect 5 V Uno GPIO directly to Pi/Nano/ESP GPIO.

Do not wire the bagged PIR/sensor boards until their exact markings/pinouts are photographed. A white PIR dome is insufficient evidence of an HC-SR501-compatible pinout.

## Shelly Motion 2

Use it as a cross-transport finished-device experiment, not the tracker. Keep it on an isolated test network and verify the installed firmware's local API. Do not make cloud enrollment part of Tracker acceptance.

## Evidence sequence

1. Existing Teltonika fixture/software tests pass.
2. Pi 3 service starts with no hardware and reports exact composition.
3. Nano BLE physical capture -> evidence -> Thing.
4. TAT140 direct TCP login/IMEI -> Codec 8 Extended frame -> durable admission -> ACK.
5. TAT140 real GNSS/movement/battery record -> normalized evidence -> Thing state.
6. Restart Pi/service -> retained state and retransmission dedupe.
7. Temporarily remove upstream reachability -> observe device/store/retry behavior without inventing delivery.
8. Restore connectivity -> prove recovery.
9. Exercise BLE sensor support only after the exact TAT140 firmware/profile and sensor protocol are qualified.
10. Record all receipts under the repository's existing evidence model.

## What not to buy yet

Do not buy a Pi 5 merely to qualify TAT140 ingress. Do not buy LoRa hardware until a LoRa profile is selected. Do not buy vendor-cloud gateways. The missing item that changes the current evidence state is the real TAT140 plus connectivity.

## Bench information still needed

Before pin-perfect wiring appendices are safe, record close-up front/back photos of the actual Nano boards, Pi PCB revision, every bagged sensor module, USB programmers/adapters, Delock model label and power supplies, plus available multimeter/logic-analyzer/soldering equipment.
