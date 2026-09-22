# TAT140 physical setup and first qualification run

This is the operator procedure for the first real TAT140 lane. It intentionally
uses direct operator-controlled infrastructure.

## 1. Before powering anything

- [ ] Photograph the product label and record the exact TAT140 order code and regional SKU.
- [ ] Record the firmware revision.
- [ ] Record the configuration-tool revision.
- [ ] Allocate a private device alias; never use the IMEI as the public Thing ID.
- [ ] Record IMEI and ICCID only in private operator notes.
- [ ] Confirm the SIM is a Swedish data SIM with the required APN.
- [ ] Confirm the endpoint path is reachable from mobile data without exposing SSH or administration ports.

## 2. Pi 3 development gateway

The current bench host is a **Raspberry Pi 3 Model B v1.2**.

Use it for Linux development and physical evidence. It does not satisfy any
separate Pi 5 product-control-panel gate.

### Base install

1. Use a known-good microSD.
2. Install a currently supported 64-bit Raspberry Pi OS Lite image.
3. Prefer wired Ethernet.
4. Set the hostname to `wotex-tracker-gw1`.
5. Configure SSH keys; disable password login after recovery access is proven.
6. Update packages and reboot.
7. Confirm stable time synchronization.
8. Confirm free disk space and storage health.

### Repository and runtime

1. Install the exact Erlang/OTP and Elixir cohort required by the repository.
2. Pin both `wotex` and `wotex-tracker` to the revisions under test.
3. Run the repository's full software gate before enabling the public-facing tracker listener.
4. Store service data and evidence on durable storage with enough free space.
5. Configure log rotation.

### Listener

- Bind only the intended interface.
- Use an explicit finite connection budget.
- Use the implemented login and frame deadlines.
- Configure a private keyed IMEI lookup.
- Do not put raw IMEI, ICCID or SIM credentials in ordinary logs.

## 3. Network topology

Preferred:

```text
TAT140 -> Swedish LTE -> operator-controlled public ingress/VPN
       -> private routed service -> Pi 3 Tracker host
```

Do not blindly port-forward a home development Pi.

If direct ingress to the Pi is used, document:

- public address ownership;
- CGNAT status;
- firewall rule;
- exposed port;
- listener process;
- management-plane isolation;
- rollback procedure.

## 4. Configure the tracker

Follow the manufacturer's current procedure for the exact firmware.

- [ ] Insert the Micro-SIM with power off.
- [ ] Configure APN and credentials.
- [ ] Configure the operator-controlled server DNS/IP.
- [ ] Configure the selected TCP port.
- [ ] Choose TCP for the first qualification lane.
- [ ] Select Codec 8 Extended to match the implemented Tracker profile.
- [ ] Enable a short lab reporting interval.
- [ ] Enable movement reporting suitable for bench tests.
- [ ] Keep GNSS enabled for the outdoor position test.
- [ ] Keep optional vendor cloud and FOTA outside the required data path.

After qualification, restore a battery-sensible reporting policy.

## 5. First wire test

Expected sequence:

```text
TCP connect
 -> IMEI/login
 -> server admission
 -> Codec 8 Extended frame
 -> parse + CRC/count validation
 -> durable observation
 -> acknowledgement
```

Record a packet capture or exact raw frame under private evidence custody, then
create a sanitized fixture with stable personal identifiers replaced.

## 6. Semantic tests

### Movement

Move the unit according to the configured movement policy. Expect one
evidence-backed movement state or event, not a synthetic application assumption.

### Battery

Record the exact IO element and value produced by the real unit and firmware.
Compare it with the profile decoder. Do not claim battery percentage if the
device proves only voltage or another metric.

### GNSS

Take the tracker outdoors with reasonable sky view. Expect:

- a valid fix;
- timestamp and freshness;
- source = GNSS;
- no impossible jump introduced by the service.

## 7. Durability and failure tests

- Restart the Tracker service before the next report.
- Repeat or force a retransmission and verify deduplication.
- Block the upstream endpoint temporarily.
- Restore reachability.
- Prove late records remain historical evidence without becoming a false current alarm.
- Verify that a lost reply does not cause an uncontrolled physical Action retry.

## 8. Optional BLE through TAT140

Only after the exact TAT140 firmware and documented sensor capability are
confirmed:

```text
qualified BLE sensor
 -> TAT140 BLE
 -> TAT140 record
 -> LTE/TCP
 -> Tracker decoder
```

Keep this separate from Pi-direct BLE discovery. A documented feature is not
hardware-qualified until the real unit produces the expected record.
