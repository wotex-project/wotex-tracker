# Teltonika ATC700 profile fixture provenance

Sources: the official
[ATC700 data-sending IO table](https://wiki.teltonika-gps.com/view/ATC700_Teltonika_Data_Sending_Parameters_ID),
[ATC700 tracking settings](https://wiki.teltonika-gps.com/view/ATC700_Tracking_settings)
and [ATC700 mobile-network settings](https://wiki.teltonika-gps.com/view/ATC700_Mobile_network),
read 2026-09-20.

The IO table documents one-byte movement identifier 240 with values zero/one,
two-byte battery-voltage identifier 67 in millivolts and one-byte battery-level
identifier 113 from zero through 100 percent. The tracking page states that the
device's data protocol is Codec 8 Extended. The mobile-network page exposes a
primary operator-selected domain, port and TCP/UDP selection; optional FOTA Web
is a separate configurable facility. These pages establish a
documentation-derived software contract, not a device or network result.

Fixture source: `test/fixtures/teltonika/atc700.json`. The committed frame is a
synthetic construction using the repository's already verified Codec 8 Extended
layout. It contains two ordered records. The first contains documented movement,
battery voltage and battery level plus a valid GNSS field; the second contains
movement, battery voltage and a no-fix GPS field. Unknown AVL 999 remains in both
records to prove byte-preserving evidence. Its SHA-256 digest is recorded beside
the vector. The bytes are intentionally identical to the compatible TAT140
protocol fixture; the profile marker, mapping, model revision, evidence identity
and provenance remain distinct.

The expected values were transcribed independently from the source table and
the frame was decoded through the generic Codec 8 Extended parser. The ATC700
profile maps only the three documented IO identifiers above and valid Codec GPS
fields. It does not infer a model from an IMEI, unknown IO field or payload
shape. Invalid mapped widths/ranges become unavailable measurements, duplicate
mapped identifiers reject the record batch, and unlisted values remain raw
transport evidence.

No physical ATC700, exact hardware or firmware revision, IMEI custody, SIM,
Swedish carrier, server configuration, packet capture, ACK exchange, power
behavior, enclosure rating, GNSS performance or BLE capability was exercised.
Those remain mandatory hardware/field gates. In particular, this record makes no
BLE sensor-gateway claim.
