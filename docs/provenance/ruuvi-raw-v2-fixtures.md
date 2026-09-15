# Ruuvi RAWv2 fixture provenance

Source: [Ruuvi format 5](https://docs.ruuvi.com/communication/bluetooth-advertisements/data-format-5-rawv2.md),
retrieved 2026-09-15. The exact 12,089-byte Markdown snapshot has SHA-256
`8e698f0d9a484c11106e3d540431a08b2450158f1f5b3c50002252d1bdf869fd`.
The committed fixture records its identity and independently transcribed protocol
facts and documented vectors; upstream narrative is not republished. The source
is a living format specification, not a firmware or physical-device qualification.

Fixture source: `test/fixtures/ruuvi/raw_v2.json`. Classification:
source-derived documentation vectors. No vector is a real-device capture from
this project. The MAC in three vectors is the source's published example and
is never used as a public Thing ID. The unavailable vector retains the all-ones
sentinel. Derived tests synthesize mixed sentinels, zero fields, framing failures
and counter edges; they do not claim hardware observations.

The decoder/profile revisions are both `ruuvi.rawv2/1.0.0`. Manufacturer data is
the two company bytes `99 04` followed by exactly 24 payload bytes; payload
integers are big-endian. Signed minima and unsigned maxima are sentinels.
Battery's 11-bit sentinel and TX power's 5-bit sentinel are independent.

Units and transformations are recorded with the fixture: Celsius in 1/200 degree,
humidity in 1/400 percent, pressure offset by 50,000 Pa, acceleration in 1/1000
standard gravity, voltage in volts from millivolts above 1,600, TX power in 2 dBm
steps above -40, and dimensionless integer counters. The source's header/range
prose contains inconsistent endpoints in places; the field widths, reserved
sentinels and explicit extreme vectors determine this revision's implementation:
pressure max 115,534 Pa, voltage max 3.646 V and TX max 20 dBm. Humidity above
100% is retained with suspect quality, never silently clamped or accepted as
physically normal. Missing values remain unavailable with nil, original raw
sentinels and a reason. No NaN, battery percentage, current motion or motion Event
is invented. Counter interpretation/deduplication belongs to later explicit rules.
