# Hardware qualification ledger

This ledger separates research candidates from real hardware evidence. Nothing listed here is `hardware-qualified` until the required direct tests exist in this repository.

| Target | Intended proof | Current status | Mandatory cloud allowed? | Required next evidence |
|---|---|---|---|---|
| Teltonika TAT140 | Required rugged GNSS/LTE Cat 1 tracker with documented BLE sensor support -> operator listener -> tracking Thing | research target; baseline hardware selected | No | exact EU hardware/firmware, BLE mode/sensor, direct endpoint configuration, real AVL capture/ack and Swedish SIM/carrier test |
| Teltonika ATC700 | Optional compact rechargeable cellular/GNSS comparison profile | documentation-fixture software profile; no hardware evidence | No | no baseline qualification required; if offered, exact hardware/firmware, direct endpoint test, real AVL capture/ack and Swedish SIM test; separately prove any BLE capability before claiming it |
| LoRaWAN tracker | Optional low-power wide-area path and fallback policy | unselected | No | choose finished compact hardware only after own-network-server/key control is proven |
| Raspberry Pi 5 host | Required headless Nerves appliance and local LiveView touch panel | research target; no image or boot test | No | WTR.14 pinned profiles, physical boot/recovery, real display/touch, separate radio qualification and UI-enabled/absent tests |
| iPhone companion | Required shared WebView application with native integrations | software loopback/Mob shell present; no mobile build or device test | No tracking vendor cloud | WTR.15 real secure storage, BLE central provisioning, push/lifecycle, offline/reconnect and signed distribution evidence |
| Smart-bike configuration | Required positioning, battery, movement and local provisioning coverage | unqualified | No | Exact device/component association, portable power/enclosure and complete WTR.09/15 workflow evidence |

## Hard rules

- Ruuvi RAWv2 is a software fixture only; no RuuviTag purchase, product hardware
  test or qualification is planned.
- A vendor dashboard/API is not sufficient evidence of openness.
- Development boards do not satisfy the finished portable tracker lane.
- The Pi 5 is a host qualification target, not a replacement for a finished portable tracker.
- Product-page feature lists do not prove protocol capabilities.
- A radio appearing in firmware/changelog material does not prove an exposed supported sensor-gateway function.
- Swedish cellular qualification records operator, SIM/eSIM, bearer, bands/model variant, attach/data behavior and fallback assumptions.
- EU868 qualification records network server, regional parameters, gateway path and real airtime/delivery evidence.

## Capture storage

Real protocol captures belong under a future `test/fixtures/hardware/<profile>/<revision>/` tree with redacted metadata and a provenance manifest. Secrets and stable personal identifiers are never committed.
