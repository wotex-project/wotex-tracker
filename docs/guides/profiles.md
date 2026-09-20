# Declarative profiles and resolution

`DeviceProfile.new/2` admits explicit atom-keyed fields: ID/version, confidence,
fingerprints, decoder and model revision pairs, mapping revision, native mapping
object and source provenance. Every interpretation-relevant field contributes to
its versioned content identity. Decoder references are inert strings; no wire
value loads a module or executes code.

`Catalogue.new/2` accepts a bounded proper list of profiles and produces one
immutable sorted snapshot. Duplicate ID/version pairs fail even when identical.
Conflicting content cannot hide behind a revision label. Resolution never reads
a mutable registry, provider stream, application environment or latest revision.

Predicate documents have one of these exact shapes:

```elixir
%{"op" => "byte", "offset" => 0, "value" => 5}
%{"op" => "length", "value" => 24}
%{"op" => "eq", "field" => "transport", "pointer" => "/manufacturer_id", "value" => 1177}
%{"op" => "member", "field" => "transport", "pointer" => "/service_uuids", "value" => "180a"}
```

Byte offsets are zero-based. Length/byte predicates only match byte payloads.
JSON fields are `ingress`, `source`, `addressing`, `radio`, `transport`,
`provenance` or `payload_json`; pointers use upstream JSON Pointer resolution.
Equality and array membership are type-strict. A missing member differs from a
present null. Names/RSSI alone cannot yield an exact or strong profile: eligible
profiles require a protocol discriminator (byte evidence or an admitted protocol,
version, codec, manufacturer or service field). This describes format evidence,
never physical SKU identity, authentication, enrollment or authorization.

`Resolution.resolve/3` admits the observation and entire catalogue first, then
evaluates every profile's conjunction of predicates. Unique best exact/strong
matches resolve. Equal best eligible matches remain ambiguous. Candidate/unknown
matches alone remain unknown with `insufficient_evidence` and retained candidates.
No match is a successful unknown domain result. Diagnostics are sorted by
profile ID/version; sorting conveys no preference. Decoder success is irrelevant.

Default catalogue/predicate/candidate limits are 256/32/256. Exhaustion returns a
typed error instead of truncating a tie. Resolution binds full observation and
catalogue content identities and the exact selected profile. `validate/4`
recomputes the result to reject stale or forged selections. Matching neither
executes a probe nor invokes a decoder. Capabilities and qualification require
the subsequent evidence-producing decoder and its independent acceptance.

## Authorized active GATT probes

The optional service package supplies an explicitly started
`Wotex.Tracker.Service.ActiveProbe` owner. Its exact
`wtr.active-probe-host.v1` configuration contains one to 32 immutable probe
plans and a finite concurrency limit. Each plan binds an exact profile ID and
version plus probe ID and revision to `ble_gatt`, the read operation, one closed
service/characteristic target, a 100–30,000 ms deadline and a 1–512 byte value
limit. Duplicate plan identities fail configuration. The target and its private
BlueZ object path are host configuration, not caller-selected routing.

A caller submits only `wtr.active-probe-request.v1`: a stable request UUID, the
complete admitted observation content identity and one configured profile/probe
identity. The owner rechecks current `interact` authority before starting a
linked, monitored adapter worker. Duplicate active IDs and exhausted concurrency
fail before transport. Caller loss, explicit cancellation and the plan deadline
kill the worker. Adapter crashes, throws and malformed returns become a closed
unavailable result; a transport permission denial remains distinct. The
adapter receives no bearer token, access proof, service handle or retained
observation.

`Wotex.Tracker.Service.BLEProbeAdapter` maps the closed request to one byte-valued
`Wotex.BLE.read/3` call on a session supplied and owned by the host. It never
opens, selects, pairs, retries or closes a peer. A successful
`wtr.active-probe-result.v1` binds the original observation, profile/probe
revision, public GATT identity, a digest covering the full private target and
canonical Base64 bytes. It is private candidate evidence only: no automatic
enrollment, strengthened resolution, capability, Thing or Action follows.
`wotex_ble` is optional, so absence leaves the probe owner unavailable and
ordinary service operation intact. Loading either package starts no radio work.
