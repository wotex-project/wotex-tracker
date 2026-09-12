# Hardware qualification ledger

This ledger separates research candidates from real hardware evidence. Nothing listed here is `hardware-qualified` until the required direct tests exist in this repository.

| Target | Intended proof | Current status | Mandatory cloud allowed? | Required next evidence |
|---|---|---|---|---|
| RuuviTag | Passive BLE scan, deterministic fingerprint/decode, environmental Thing | research target | No | authoritative format revision, real capture, live scan, decoder fixture |
| Teltonika TAT140 | Finished rugged direct cellular tracker -> operator listener -> tracking Thing | research target | No | exact hardware/firmware, direct endpoint configuration, real AVL capture/ack, Swedish SIM test |
| Teltonika ATC700 | Compact rechargeable cellular/GNSS tracker | research target | No | exact firmware/config path, direct endpoint test, AVL evidence; separately prove any BLE capability before claiming it |
| LoRaWAN tracker | Optional low-power wide-area path and fallback policy | unselected | No | choose finished compact hardware only after own-network-server/key control is proven |

## Hard rules

- A vendor dashboard/API is not sufficient evidence of openness.
- Development boards do not satisfy the finished portable tracker lane.
- Product-page feature lists do not prove protocol capabilities.
- A radio appearing in firmware/changelog material does not prove an exposed supported sensor-gateway function.
- Swedish cellular qualification records operator, SIM/eSIM, bearer, bands/model variant, attach/data behavior and fallback assumptions.
- EU868 qualification records network server, regional parameters, gateway path and real airtime/delivery evidence.

## Capture storage

Real protocol captures belong under a future `test/fixtures/hardware/<profile>/<revision>/` tree with redacted metadata and a provenance manifest. Secrets and stable personal identifiers are never committed.