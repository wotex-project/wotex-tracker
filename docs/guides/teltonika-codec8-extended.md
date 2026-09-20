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

`Wotex.Tracker.Protocols.Teltonika.TCPSession` separately parses the documented
two-byte length and 15 ASCII IMEI digits. It retains at most one 17-byte partial
login and returns any coalesced AVL bytes without decoding them, allowing the
host to admit the login before processing telemetry. A keyed HMAC lookup avoids
retaining a raw IMEI in configuration, but neither the IMEI nor CRC is device
authentication.

After durable admission, the session seam maps accepted and duplicate commits
to the complete four-byte record-count ACK, a known rejection to a zero ACK and
an unknown commit outcome to connection close without an ACK. Decoding success
alone is never permission to reply. The host must still admit the private login,
serialize per-device commits and reconcile retransmission after an unknown
outcome.

The service package's explicitly started `Cellular.Ingress` process owns the
next trusted-host boundary. A finite configuration maps the keyed digest to one
private bearer, scope and operator label. It revalidates the decoded frame,
serializes all packet admission and stores the complete frame as one cellular
observation. Operation and observation identities are deterministically derived
from the keyed device identity and exact frame. On reconnect it checks the
durable receipt before submitting, so a commit whose response was lost becomes
a duplicate full ACK rather than a second observation. Raw IMEI digits never
enter the observation or process state.

These pure slices cover TCP login, data framing and ACK decisions only.
The service bridge covers configured durable admission and retransmission
reconciliation. Socket ownership, deadlines, connection loss, a software wire
peer, command codecs, UDP, TAT140 IO semantics, a device profile and live
hardware evidence remain separate acceptance work.
