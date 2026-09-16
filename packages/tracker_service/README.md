# Tracker service components

Explicitly started service components live here. Loading this package starts no
Tracker listener or store. The pure `wotex_tracker` package has no dependency on
this package. The durable-store contract and current acceptance scope are in
the repository's `docs/contracts/service-v1.md`.

Development uses `WOTEX_PATH_DEPS=1 MIX_ENV=test mise exec -- mix check --no-retry`
from this directory. Production resolves normal package artifacts. The local
workspace switch is rejected in production.

Install the independent OpenAPI/client verification tools from the repository
root before running the gate:

```sh
python3 -m venv _build/openapi-venv
_build/openapi-venv/bin/pip install -r scripts/requirements-openapi.txt
```

`Wotex.Tracker.Service.new/1` takes an explicit `Store` handle, `Credentials`
value and public `base_url` origin. It loads the packaged RAWv2 catalogue and
environmental model. The host owns time, credential custody and supervision.
Every facade operation authenticates an ephemeral bearer token and exact scope.

The facade supports imported observations, public inspection and paginated
snapshots, encrypted event cursors, privileged byte-preserving raw exports,
operator-confirmed enrollment and reassociation, materialisation, structured
measurement analytics, revocation and operation-status lookup. Mutations take a
lowercase UUIDv4 operation ID and a decimal-string
expected generation. The original committed receipt is replayed before new
profile/model work, including its generated Thing ID. Unknown outcomes require
receipt lookup; they do not authorize automatic physical Action retries.

The privileged `Store` port also supports bounded durable store-and-forward for
host adapters. `ForwardItem` separates bearer from application protocol and
declares source reliability plus the exact required acknowledgement layer.
Per-scope defaults allow 1,024 pending items, 16 MiB encoded bytes, seven days
and eight attempts; configuration may only lower those ceilings. Claims commit
attempt/retry state in FIFO order before delivery. Reliable overflow rejects,
while lossy overflow records a discarded receipt. Pending/unknown delivery does
not remove an item. Exact send or layered acknowledgement completion is
idempotent, and terminal cleanup is explicit. This privileged API is not exposed
as an unauthenticated HTTP queue.

The privileged `Store` port can also atomically persist validated
`TransportDegradation`, `HeartbeatTransition`, `BatteryTransition`,
`MotionTransition` and `GeofenceTransition` results. `RuleTransition` rechecks the pure result; the SQLite
commit compares the prior state identity and records canonical state, state
history, a stable event intent and its event at one scope generation. Motion
and geofence state retain deduplicated registries of their complete
evidence-bound samples.
Exact retries are idempotent, stale writers conflict, and restart recovery reads
the native JSON state back through the pure constructor. Replay event intents
retain prohibited dispatch, while live event intents retain the need for separate
authorization. Deadline scheduling, notification delivery and public HTTP rule
management remain outside this host port.

Stateless rule results use the same intent and public-event tables through
`RuleEvent`. Its crossing constructor restores complete fence, endpoint and
policy documents, while its suspicious-movement constructor restores the motion
state and both evidence-backed facts. Each re-evaluates the pure result before
commit. A new stable event advances the scope once; an exact retry returns the
original generation. The recorded mode and physical-action metadata cannot be
changed by replaying the same event identity through another mode.

`GET …/{resource}/{id}/history` returns ascending public versions, including
explicit deletion records, with `limit` and encrypted `cursor` pagination.
Pages stay at one committed generation and provide an event cursor for the same
snapshot. Current authorization applies to every page. Missing history is 404;
expired cursors require a new snapshot. History uses the existing fixed storage
capacity and 4 MiB response limit; smaller pages may be needed for large records.

Enrollment issues a random UUID pseudonym for an explicitly confirmed observation.
It does not authenticate the radio device or associate future packets implicitly.
Materialisation persists a validated upstream TD, initial state and private
lineage together. Forms use the configured origin and the service Property API.
Runtime `ExposedThing` dispatches authorized reads against the TD and state from
one committed generation. Unavailable measurements return HTTP 503. Explicit
host delivery evidence enables observation of committed Property values. Physical
Actions remain unsupported. No Directory destination or
publication effect is implicit.

An `enroll` grant can derive initial state/evidence for the same Thing in its
materialisation transaction. It cannot import observations or export raw data.
Resource reads need `read`; raw exports need `raw`; revocation needs `admin`.
Scanner and public rule management remain explicitly unsupported. Analytics is
reported as `structured_queries`.

`Service.analytics/5` and `POST …/analytics/query` accept the closed
`wtr.query-spec.v1` document. The service rechecks `read` authority inside a
dedicated read-only SQLite transaction, pins the current scope generation and
extracts numeric measurement rows from committed state history. It scans at most
100,000 matching rows across one to eight explicit series and returns a
content-identified `wtr.query-result.v1` with disclosure counts and preserved
gaps. The operation is read-only, so it does not use mutation receipts or
`Idempotency-Key`.

Analytics execution is capped at eight concurrent queries, two per principal and
sixteen starts per principal in each one-second window. Caller loss, store
shutdown or the configured timeout cancels the dedicated SQLite connection and
retains no query reservation. These limits are independent of the serialized
writer, so a canceled scan cannot leave the writer mailbox blocked.

Administrators can persist a `wtr.saved-query.v1` definition with one admitted
absolute-window `QuerySpec` and closed line/area/points/table visualization
options. Save, update and delete are idempotent generation-checked transactions;
ownership is stored privately and projected as a scope pseudonym. Ordinary
resource reads and history expose reviewed definitions and deletion tombstones.
`GET …/saved_queries/{id}/execute` rechecks current `read` authority and runs the
exact stored query through the same bounded engine. Possessing or sharing a
definition grants no data access and does not call a model. Pagination, rolling
windows, named display timezones, prompting, operational telemetry and graph
rendering remain later contracts.

## Explicit HTTP instance

The package includes a caller-started Bandit/Plug listener. It has no application
callback. With an existing private absolute `directory` and admitted `credentials`:

```elixir
{:ok, server} = Wotex.Tracker.Service.HTTP.Server.start_link(
  directory: directory,
  credentials: credentials,
  ip: {127, 0, 0, 1},
  port: 4000,
  exposure: :loopback,
  public_origin: :listener
)
```

Use `port: 0` only when an ephemeral port is wanted; `listener_info/1` returns
the actual address. Production TD URLs need a stable configured origin. TLS mode
requires `exposure: :tls`, an HTTPS `public_origin` and absolute `tls` certificate
and key paths. Explicit `:proxy` mode requires an HTTPS public origin and a
protected proxy-to-listener network; forwarded headers never supply authority or
Forms. No remote exposure is inferred.

OpenAPI **3.1.0**, contract revision **1.7.0**, is packaged at
`priv/openapi/v1.json` and served at `/api/v1/openapi.json`. Liveness is
`/health/live`; authenticated resources are under `/api/v1/scopes/{scope}`.
Use `Authorization: Bearer …`, and a UUIDv4 `Idempotency-Key` for POST mutations.
The read-only analytics POST uses authorization without an idempotency key.
Saved-query writes use the same mutation receipt/idempotency contract as other
durable resources; saved-query execution is a read-only GET.
API responses have `schema: wtr.response.v1` and `data` or `error`. Successful
TD Property reads return the native JSON scalar with `X-Wotex-Generation`.
Unknown
mutation outcomes use HTTP 202; query the same operation ID. Raw exports use
their own media types and preserve bytes/native types.

SSE is `/events/stream` below the scope. Supply exactly one initial `cursor`
query parameter or resumed `Last-Event-ID` header. Transport IDs are encrypted
cursors; deduplicate the stable domain `data.id`. Streams close on revocation,
expiry, storage failure or their five-minute lifetime. Reconnect/resnapshot
according to the returned error. Tokens never belong in URLs.

The listener caps 32 requests, 16 streams and 64 connections per instance.
Requests after header admission have a five-second hard deadline; header reads
have a five-second idle timeout and finite byte/count limits. HTTP/2, WebSockets
and compression are disabled in this qualified slice. The caller owns shutdown;
active stream shutdown is tested below the ten-second budget.

## Runtime software peer

`HTTP.LoopbackClient.new(origin, scope)` admits one numeric HTTP loopback origin
and scope for Property reads and SSE observation through `Wotex.Binding.HTTP`. Pass the
result as the binding client configuration, and supply a caller-owned Runtime
credential provider separately. That provider must retain only opaque custody
references in the consumed Thing; resolve each bearer token immediately before
execution. Finite-read tests use private caller-owned ETS; subscription tests use
a caller-owned credential vault because Runtime resolves credentials in its
opening worker. Neither transport plans nor long-lived readers retain tokens.

The client uses Mint 1.10.0 with a five-second maximum deadline, one socket per
call, at most 1 MiB of response data, 32 headers and 8 KiB of header/status-line
data, or the binding's smaller limits. It does not resolve DNS, use a proxy,
follow redirects or retry. Socket ownership follows the caller and every return
path closes it. Subscription opening monitors owner/caller before connecting;
after the handshake each stream owns one monitored reader, bounded to 300 seconds,
32 KiB frames and 32 queued owner messages. Close, owner loss, malformed input,
overload or deadline closes that connection without reconnect. Two simultaneous
Runtime subscriptions, independent close, resume and revocation are exercised.

`GET …/things/{id}/properties/{property}/observe` initially delivers the current
native value, then committed Thing updates. Optional Property-specific `cursor`
or `Last-Event-ID` resumes delivery; gaps in availability close the stream and
require an explicit fresh snapshot after recovery. Stable SSE event metadata
supports deduplication; the scalar body remains compatible with the TD. The repository contract is documented in `docs/contracts/service-v1.md`.
Remote peers and physical sensor subscriptions remain separately qualified.
