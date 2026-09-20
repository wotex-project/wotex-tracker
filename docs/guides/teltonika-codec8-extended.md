# Imported Teltonika Codec 8 Extended framing

`Wotex.Tracker.Protocols.Teltonika.Codec8Extended` is a pure protocol boundary
for documented TCP AVL data packets. It does not open a socket, identify a
physical product, authenticate an IMEI or acknowledge data before a host commits
it.

```elixir
alias Wotex.Tracker.Protocols.Teltonika.Codec8Extended

state = Codec8Extended.new_stream()
{:ok, state, packets} = Codec8Extended.feed(state, tcp_chunk)
:ok = Codec8Extended.finish(state)
```

`feed/2` accepts arbitrary TCP split boundaries and at most 16 complete frames in
one chunk. It retains less than one 1,292-byte frame between calls. The data field
is limited to the documented 1,280 bytes. A zero preamble, declared length,
`0x8E` codec, both record counts and CRC-16/IBM must agree before any packet is
returned. EOF with retained bytes is a malformed incomplete frame rather than a
successful empty read.

Each record retains its Unix-millisecond timestamp, closed priority, GPS wire
fields, event IO identifier and ordered IO elements. Fixed-width values retain
both their exact bytes and unsigned integer. Variable-width and unknown IO
identifiers remain raw bounded bytes; this generic codec does not invent a
device-specific meaning. A record with zero satellites keeps its raw last-fix
coordinates but exposes no normalized coordinate and is marked unavailable, as
required by the protocol's no-fix rule. Available out-of-range coordinates or
angles are suspect and likewise have no normalized coordinate.

After durable admission, `acknowledgement/1` creates the protocol's four-byte
accepted-record count. Decoding success alone is not permission to send it. The
host session must first admit the 15-digit IMEI against private configuration,
serialize per-device commits and choose the count from the actual commit result.
CRC detects accidental corruption; it is not device authentication.

This slice covers TCP data framing only. IMEI negotiation, socket ownership,
timeouts, retransmission, command codecs, UDP, TAT140 IO semantics, a device
profile and live hardware evidence remain separate acceptance work.
