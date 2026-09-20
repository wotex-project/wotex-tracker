# Teltonika TAT140 profile fixture provenance

Sources: the shared
[TAT100 AVL ID list](https://wiki.teltonika-gps.com/view/TAT100_AVL_ID_List)
and [TAT140 system settings](https://wiki.teltonika-gps.com/view/TAT140_System_settings),
read 2026-09-20. These are living manufacturer pages, so this record fixes the
review date and interpreted claims rather than asserting an immutable upstream
snapshot.

The AVL table lists TAT140 hardware support for movement identifier 240 as a
one-byte unsigned value, with zero meaning off and one meaning on. It lists
battery-voltage identifier 67 as a two-byte unsigned value scaled by 0.001 V.
The same table does not list TAT140 support for battery-level identifier 113, so
the profile deliberately preserves that identifier as unsupported raw IO rather
than exposing a battery percentage. The system settings page establishes that
TAT140 can be configured for Codec 8 Extended; it does not prove the setting on
a physical unit.

Fixture source: `test/fixtures/teltonika/tat140.json`. The committed frame was
constructed from the documented Codec 8 Extended layout with two records. The
first has a valid GNSS fix, movement on, battery voltage 3.600 V and unsupported
identifiers 113 and 999. The second has no GNSS fix, movement off, battery
voltage 3.590 V and unsupported identifier 999. Its decoded bytes have SHA-256
`2d1b68bc4ac72d6dbebe5028c39a1c2c96a42e992e50796b285dbdff694e8f8e`.
It is a synthetic documentation fixture, not a manufacturer example or hardware
capture.

The profile match requires cellular ingress, the Teltonika TCP adapter, Codec
`0x8E` and an exact operator-configured profile marker. This is strong
deterministic profile-format evidence, not device authentication or automatic
SKU discovery. The mapper retains record order, every IO element and the event
IO identifier. It rejects duplicate mapped identifiers, retains invalid known
values as unavailable measurements with their raw bytes, and emits a normalized
position only for a valid Codec GPS fix. It invents no horizontal accuracy or
battery percentage.

No physical TAT140, firmware, IMEI custody, SIM, carrier, server configuration,
real AVL capture, command path or lifecycle operation was tested. The hardware
ledger therefore remains `research target`.
