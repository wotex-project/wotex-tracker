# Teltonika Codec 8 Extended fixture provenance

Source: [Teltonika AVL Protocols](https://wiki.teltonika-gps.com/view/Teltonika_AVL_Protocols),
read 2026-09-20. The living manufacturer page defines Codec ID `0x8E`, TCP
preamble and length coverage, two matching record counts, CRC-16/IBM coverage,
GPS and IO layout, variable-width IO elements, IMEI negotiation and four-byte
record-count acknowledgement. Its revision history was not available during
this review, so this is a dated source record rather than an immutable source
snapshot.

Fixture source: `test/fixtures/teltonika/codec8_extended.json`. The committed
vector is the page's one-record Codec 8 Extended TCP example with presentation
spacing removed and no byte changed. Its decoded bytes have SHA-256
`c577a70391f8cc65be9cb84f6c19553e2b49f3be388a9f842bc948f021f2bbae`.
The fixture records the source URL, retrieval date and transformation. It is a
documentation vector, not a project capture or evidence from a TAT140.

The source example independently fixes the timestamp, all four fixed IO widths,
five IO identifiers, their order and CRC `0x2994`. Tests additionally construct
synthetic valid-position and variable-width records, then exercise every TCP
split boundary, coalesced frames, incomplete EOF, bad preambles, unsupported
codecs, count mismatches, invalid priority, CRC corruption and resource limits.
Those derived cases test implementation behavior and make no manufacturer or
hardware claim.

[TAT140 system settings](https://wiki.teltonika-gps.com/view/TAT140_System_settings),
read 2026-09-20, state that the device can be configured for Codec 8 or Codec 8
Extended. That establishes a candidate protocol relationship only. Exact model,
hardware revision, firmware, IMEI custody, selected IO configuration, direct
endpoint behavior and a real capture remain required before a TAT140 profile can
graduate beyond research.
