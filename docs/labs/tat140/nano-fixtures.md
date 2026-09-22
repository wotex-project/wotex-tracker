# Nano 33 IoT Tracker fixtures

The Nano boards are deterministic open fixtures for discovery and capability
tests around the real TAT140. They are not substitutes for finished tracker
qualification.

## Board handling

The retail boxes are marked **WITH HEADERS**. Inspect the actual boards before
soldering. If the headers are factory-soldered, do not rework them.

If headerless:

1. Remove all power.
2. Use a breadboard to hold two 2.54 mm header rows square.
3. Place the Nano over the headers.
4. Tack one corner per row.
5. Verify alignment.
6. Tack opposite corners.
7. Solder the remaining pins.
8. Inspect for bridges.
9. Continuity-check suspicious pins.
10. Boot by USB with no external wiring.

Nano 33 IoT GPIO is 3.3 V.

## Fixture A: passive BLE capability beacon

Purpose: exercise Tracker observation → fingerprint → capability evidence
without vendor hardware.

Advertisement payload v1:

```text
byte 0     protocol version = 0x01
byte 1     capability bitmap
           bit0 motion
           bit1 battery
           bit2 owner-presence test
byte 2     flags
           bit0 motion active
           bit1 owner present
byte 3     battery percent 0..100, 0xFF unknown
byte 4..7  monotonic sample counter uint32 big-endian
```

Identity must not derive solely from the BLE address. Firmware test mode should
rotate private addresses while keeping an application-level fixture identifier
available through the authorized profile or probe path.

## Fixture B: bounded GATT probe

Expose:

- Device Revision characteristic;
- Motion characteristic;
- Battery characteristic;
- optional Owner Presence test characteristic.

The probe is read-only for baseline tests.

## Fixture C: PIR input

Use the confirmed Adafruit ADA189 only after checking its authoritative supply
and output characteristics against the Nano's 3.3 V input limit. Do not assume
every PIR board is the same.

The expected semantic pipeline is:

```text
PIR electrical state
 -> Nano firmware
 -> versioned BLE evidence
 -> Tracker profile
 -> motion capability/property/event
```

## Negative cases

- unknown advertisement version;
- truncated payload;
- impossible battery value;
- counter replay;
- BLE private address change;
- ambiguous profile;
- GATT probe unavailable;
- stale owner-presence evidence.

No AI participates in an admission decision.
