# Tracker hardware lab template

Use this template for each future finished tracker family.

## Identity

- **Lab ID:** `<tracker-family>/<regional-sku>`
- **Tracker model/SKU:** exact order code
- **Firmware:** exact revision
- **Radio region:** explicit
- **Primary application protocol:** explicit
- **Operator-controlled endpoint:** required
- **Vendor cloud dependency:** must be none
- **Evidence status:** planned | fixture | integration | hardware-qualified | field

## Requirements mapping

List the exact WTR contracts and product requirements exercised by this lab.

## Hardware

| Qty | Part | Exact identity | Role |
| ---: | --- | --- | --- |
|  |  |  |  |

## Network path

Draw every hop from tracker to Tracker service. Separate the radio bearer from
the application protocol.

## Configuration

Record:

- SIM/APN class without secrets;
- server DNS/IP and port;
- TCP/UDP choice;
- codec/protocol revision;
- reporting/movement/GNSS policy;
- BLE/sensor features if selected.

## Acceptance

- [ ] exact hardware identity captured
- [ ] direct operator-controlled connectivity
- [ ] protocol login/identity
- [ ] first real frame
- [ ] ACK semantics
- [ ] position
- [ ] movement
- [ ] battery
- [ ] restart/retransmission
- [ ] outage/recovery
- [ ] privacy/redaction review
- [ ] sanitized fixture committed
- [ ] evidence manifest recorded

## Negative tests

Include invalid login/identity, truncated frame, wrong CRC/checksum,
duplicate/replay, stale record, impossible position, timeout, server restart and
unexpected firmware/protocol revision where applicable.
