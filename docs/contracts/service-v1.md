# Service v1 foundation contract

This pins the implementation boundary before storage and listener code. It is
an incremental implementation of WTR.06/07/08, not a product-readiness claim.

## Storage and ownership

The service package uses Exqlite **0.40.0**, its bundled SQLite, and the direct
`Exqlite.Sqlite3` API. No Ecto or database server is involved. A caller explicitly
starts one writer process for a local database; separate connections/processes
are serialized by SQLite `BEGIN IMMEDIATE`. Each unit writes the observation,
deduplication record, versioned domain records, event intents and publication
intent in **one** transaction. The expected per-scope generation is checked
inside that transaction. Readers use a read transaction or immutable historical
generation. Scope generations and sequence cursors are decimal strings, never
browser numbers. Native evidence JSON preserves `1` versus `1.0` and wide
integers. Byte payloads use WTR.01's canonical Base64 envelope.

The internal read port accepts a snapshot generation with its exact event
high-water cursor for a fresh snapshot-to-stream handoff. This also works when
a quiet scope's last event predates retention. Subsequent events still obey
retention. The HTTP layer must bind this pair, principal, scope and issue/expiry
time in its authenticated cursor; raw storage tokens do not grant authority.

Schema version 3 is created transactionally using `PRAGMA user_version`.
Version 1 upgrades through the forward-queue schema and then the rule-state
schema in the same startup transaction; version 2 adds only the rule-state
tables. Existing scopes, operations, observations, records, events,
publications and queue items remain unchanged. Unknown newer schemas fail
startup. Migrations may never silently reset data.
WAL, `synchronous=FULL`, foreign keys, a 1,000 ms busy timeout, 1,000-page
auto-checkpoint and a 262,144-page database ceiling are mandatory. Page size is
4,096 bytes. Checkpoint is an explicit administrative operation. Backup uses
SQLite `VACUUM INTO` to a fresh private file, never copies a live main file
without its WAL. Restore occurs offline into a fresh private directory and
must pass SQLite integrity and schema checks before listener startup.

The operator supplies an existing absolute private directory (0700) on a local
filesystem. The store rejects symlinks along the configured path, nonregular
database/sidecar files and multiply linked database files. The database is 0600.
This assumes trusted same-user processes, a trustworthy parent directory and a
filesystem honoring SQLite locking/fsync. It does not provide race-proof
containment against a hostile concurrent same-user filesystem writer. Network
filesystems and physical power-loss durability remain unqualified.

## Transactions, retention and recovery

A mutation has explicit principal, scope, idempotency key, expected generation,
admitted request JSON and receiver time. Idempotency covers principal/scope/key
and the complete type-strict admitted request (including expected generation).
An identical retained operation returns its original committed result; different
content conflicts. A duplicate observation ID with different content conflicts.
An identical observation under a new key may record that operation without a new
generation, event or state transition. This prevents repeated live effects.

Operation outcomes are `not_committed`, `committed` (with generation and separate
publication status), or `unknown`. A lost reply is unknown; clients query the
same operation identity and never automatically retry a physical Action.
Committed results are retained for seven days of explicit receiver time;
expired keys remain tombstones and return `operation_expired`. Expiry cannot
silently permit re-execution. Event cursors expire after seven days; a cursor
outside retained history requires an explicit resnapshot. The first store
retains evidence/history and expired tombstones until explicit operator-managed
offline retention; it rejects at capacity rather than silently deleting linked
evidence. Automatic retention/deletion and backup erasure remain separate work.

Publication intents contain the exact Thing/deployment document and generation.
Publication is a separate effect. Only the latest generation for that Thing may
be attempted. The publisher must reconcile an idempotent remote operation and
conditional generation; unsupported remote conditional writes are explicitly
unavailable. A crash after remote success before local confirmation remains
pending/unknown until reconciliation. Cleanup failure is separate from committed
admission and confirmed publication. No retry can overwrite a newer publication.

The privileged host store also provides a durable store-and-forward queue. Each
item fixes scope/item identity, selected bearer and application protocol, source
reliability, native JSON payload, admission time and required acknowledgement
layer. Admission records a content digest and captures the configured age and
attempt limits in the row, so a restart or later configuration change cannot
extend that item's budget. Pending items are claimed by admission time then item
ID. Claim commits the attempt number and next retry time before bytes leave the
process. A lost claim reply therefore delays a stable item; it does not remove it.

Queue count and encoded-byte ceilings apply per scope. A reliable source receives
`queue_full` without a commit or acknowledgement. A lossy source receives a
durable discarded receipt with reason `overflow` when receipt capacity remains.
Exact expiry and exhausted attempts become discarded receipts before another
claim. Completion requires a prior claim, the exact item digest and either
`sent` for a route requiring no acknowledgement or `acknowledged` at the exact
declared layer. A lower/different layer does not satisfy it. Terminal receipts
remain until explicit scoped cleanup; cleanup never removes pending items.

The same privileged store accepts a revalidated transport-health, heartbeat,
low-battery, motion/trip or geofence transition. It compares the expected prior state identity inside
`BEGIN IMMEDIATE`, then
writes the canonical rule state, immutable state history, deduplicated event
intent and public event at one scope generation. An exact retry returns the
original generation. A stale prior identity or a reused event ID with different
content conflicts without a partial write. Live event intents retain that a
physical Action still needs separate authorization; replay event intents retain
that dispatch is prohibited. The current port does not schedule evaluation,
deliver notifications or expose rule mutation over HTTP.

Event-only rules use the same intent and public-event tables without manufacturing
canonical state. The prepared host value retains complete closed inputs and the
pure result, re-evaluates them during admission, and binds its own identity. A new
event ID advances the scope and writes both rows atomically. An exact event retry
with the same mode/effect returns the original generation; changed content or
live/replay effect metadata conflicts. Inferred geofence crossings and suspicious
movement alarms use this path.

## Finite budgets

These are service ceilings, not radio protocol maxima. Operator configuration
may lower them. Enlarging them requires a new qualified contract.

| Resource | Ceiling / behavior |
| --- | --- |
| Request body / prepared transaction | 1 MiB each; reject before JSON parsing |
| Observation | WTR.13 core limits; one per admission transaction |
| Domain records per transaction | 16; 256 KiB per record |
| Events per transaction | 16; 16 KiB per event; public projections only |
| Page / event replay batch | 100 records / 100 events; 4 MiB response ceiling |
| Concurrent requests / streams | 32 / 16 per instance; reject excess |
| Store callers | 32 outstanding reservations; reject before mailbox enqueue |
| Request / SQLite busy deadline | 5,000 ms / 1,000 ms |
| SSE poll / idle reauthorization | 1,000 ms; no per-subscriber event queue |
| SSE write / connection lifetime | 5,000 ms / 300,000 ms; reconnect with cursor |
| Shutdown | 10,000 ms; unacknowledged mutations remain unknown |
| Retained operations / records / events | 100,000 each per database; reject at capacity |
| Canonical rule states / rule event intents | 100,000 each per database; reject at capacity |
| Main database | 1 GiB; WAL/temp files require additional free space |
| Operation / replay retention | 7 days; expiry explicit; fail closed at row capacity |
| Forward item payload | 256 KiB native JSON before queue framing |
| Pending forward queue | 1,024 items and 16 MiB encoded bytes per scope |
| Forward age / attempts | 7 days / 8 attempts, captured at admission; operator may lower |
| Forward claim | 100 due items; retry delay 1 ms–24 h; FIFO by admission time then ID |

Readiness checks actual writable storage separately from liveness and ingress
capabilities. Passive BLE absence is `unsupported`, never a successful empty scan.
No listener defaults to remote binding, no URL credentials, and no unauthenticated
loopback privilege. Only reviewed public projections are eligible for HTTP/SSE;
raw evidence requires a separate scope and a byte-preserving export response.

## Credential and cursor boundary

The implemented host credential value holds at most 32 SHA-256 hashes of
canonical 256-bit bearer tokens, with explicit principal, expiry and at most 16
scope grants per credential. Allowed permissions are `read`, `ingest`, `enroll`,
`raw`, `admin` and `interact`; none implies another. The host supplies a stable
instance ID and 32 random secret bytes. Inspection omits hashes, secret keys and
access proofs. No credential or clock source is implicit.

Proofs bind the current credential digest, principal, scope, instance and expiry.
The host rechecks its latest configuration. A configured store also checks
durable scope revocation before reads, delivery and mutations. Mutations check
inside `BEGIN IMMEDIATE`, before idempotent replay. Required grants are derived
from all affected record kinds: ingestion cannot insert enrollment, policy or
revocation records. Revoked credential IDs cannot be reused in that scope;
rotation uses a new ID. Revocation records are retained with other evidence.
Clock readings passed to these ports must come from the host, not request JSON.

The low-level Store handle remains a privileged host port. The public service
facade authenticates every call, including local calls, and uses guarded read
ports. A transport must also reauthorize immediately before each stream delivery.
These primitives are not HTTP/session or complete access-audit acceptance.

Cursor format `wtrc1` uses AES-256-GCM, fresh 96-bit nonces, an authenticated
instance/principal/scope/purpose binding and explicit issue/expiry times. Internal
sort keys are encrypted, not merely Base64-encoded or signed. Keys are derived
separately for cursors and scope-specific observation pseudonyms. A cursor never
grants access. Page cursors pin kind, generation, lexical ascending ID order,
last ID and page size. Event cursors distinguish the snapshot high-water handoff
from a replay position within a multi-event generation. Retention expiry and key
rotation require resnapshot. Query filters will need an explicit versioned
extension to this closed cursor schema when those queries are implemented.

Ordinary projections omit source/addressing/radio/provenance, hardware IDs and
raw decoder interpretation. Scalar values use a closed tagged representation:

| `type` | `value` |
| --- | --- |
| `integer` | JSON integer within ±9,007,199,254,740,991 |
| `wide_integer` | Canonical decimal string outside that range |
| `number` | JSON floating-point number |
| `boolean` | JSON boolean |
| `null` | JSON null |

Thus `1` and `1.0`, false and null remain distinct to a browser. Raw evidence
exports instead preserve the original WTR.01 native representation and bytes;
the frontend must download those bytes without parse/re-encode. The concrete
HTTP envelope is `wtr.response.v1`; its packaged OpenAPI 3.1.0 document and
stream rules are described below.

## Authenticated domain operations

`Wotex.Tracker.Service` implements import, public list/get, private raw exports,
enrollment, materialisation, durable event reads, revocation and caller-scoped
operation lookup. The host supplies the current authorization time. Mutation
operation IDs are canonical lowercase UUIDv4 strings. Request objects have closed
keys; generation strings are canonical nonnegative decimals.

| Mutation | Required permission | Exact request fields |
| --- | --- | --- |
| `submit` | `ingest` | `observation` (WTR.01 envelope), `expected_generation` |
| `enroll` | `enroll` | `observation_id` (public pseudonym), `title` (1–256 UTF-8 bytes), `owner_confirmed` (`true`), `expected_generation` |
| `associate` | `enroll` | `thing_id`, `observation_id`, `owner_confirmed` (`true`), `expected_generation` |
| `materialize` | `enroll` | `thing_id` (issued UUID URN), `expected_generation` |
| `revoke` | `admin` | `credential_id`, `expected_generation` |

Successful imports return `data.observation_id`; enrollment returns
`data.thing_id`; association returns that Thing ID, the selected public
`observation_id` and a new `association_id`; materialisation returns the Thing ID
and `materialisation_id`.
Generated IDs are stored in the atomic operation receipt. After authentication
and request admission, exact replay returns that receipt before consulting a
new catalogue or model. A new request still checks its generation and authority
inside the final write transaction. Known preparation failures are
`not_committed`; only uncertainty after attempting a write yields `unknown`.

Enrollment requires a resolved observation from the current exact catalogue
identity. It records the confirming actor privately and issues a random UUIDv4
pseudonym and association ID. The assertion means the operator confirmed this
association; it does not authenticate RAWv2 hardware or authorize automatic
association of future captures. Preparation uses the request's exact committed
generation for every dependent read. Historical source data is retained.

Association confirms a later admitted, resolved observation for an existing Thing.
It retains the public Thing ID and title, creates a new private association and
identity revision, and appends an enrollment version/event atomically. It requires
`enroll` authority and explicit confirmation; it does not infer association from
MAC/IMEI/payload similarity. Current TD/state remain at their prior committed
version until a separate conditional `materialize` mutation. Both versions remain
inspectable in history. Importing another packet alone never updates a Thing.

Materialisation consumes the enrolled observation with its pinned catalogue,
adds explicit operator evidence, and uses the pure core plus upstream validation.
It stores the TD, initial state, private provenance and full evidence together.
`enroll` permits initial `state`/`evidence` records only alongside a non-null
`things` record of the same ID. Other observation/state ingestion still requires
`ingest`. The configured origin supplies reserved property URLs below
`/api/v1/scopes/{scope}/things/{thing_id}/properties/{property}`; every segment
is percent encoded. No request Host header or device addressing supplies a Form.
No external publication intent is created without a configured destination.
The current facade does not itself start a listener or prove endpoint reachability.

Public resource names are `observations`, `resolutions`, `evidence`, `state`,
`enrollments`, `things` and `saved_queries`. Lists accept only `limit` (default
25, maximum 100) and `cursor`. A page returns `items`, `generation`, nullable
next-page `cursor` and a `stream_cursor` for its exact snapshot. Each item has
`id`, `generation` and reviewed `value`. Observation/resolution pages cannot
reuse each other's cursors even though they share a private storage index. Raw
exports return native JSON bytes through `raw`, never the public tagged-scalar
transformation.

Event reads return `items` and a resume `cursor`. Each event has a stable decimal
domain `id`, generation, versioned event schema and public event data. Its
encrypted transport `cursor` can change on replay; clients deduplicate the
domain ID. Cursor encryption, retained IDs and current authorization remain
separate checks. An empty event batch preserves the supplied cursor.

## HTTP and stream contract 1.9.0

The packaged `priv/openapi/v1.json` uses OpenAPI **3.1.0** with JSON Schema
2020-12. The independently maintained Elixir audit checks document shape,
operations, parameters, responses, schemas and internal references. A separate
BEAM process validates actual request/response bodies against the packaged
schemas while exercising HTTP and SSE directly.

The listener uses Bandit **1.12.5**, Plug **1.20.3** and Thousand Island **1.5.0**.
Start `Wotex.Tracker.Service.HTTP.Server` explicitly with a private directory,
credential value, bind IP/port, public origin and exposure mode. Plain HTTP is
limited to explicit loopback mode, or an explicitly trusted proxy deployment
with an HTTPS public origin and operator-protected internal network. Direct TLS
requires explicit certificate/key paths. Forwarded/Host headers never determine
Forms or authorization. Loading the service package starts no Tracker instance.

| Path | Method / purpose |
| --- | --- |
| `/health/live` | GET public liveness |
| `/api/v1/openapi.json` | GET public machine contract |
| `/api/v1/scopes/{scope}/health/ready` | GET authenticated writable-store check |
| `/api/v1/scopes/{scope}/capabilities` | GET explicit available/unsupported/unconfigured status |
| `…/analytics/query` | POST one read-only structured measurement query against a committed snapshot |
| `…/analytics/pages` | POST one snapshot-pinned bucket page with an encrypted continuation |
| `…/observations`, `…/resolutions`, `…/evidence`, `…/state`, `…/enrollments`, `…/things`, `…/saved_queries` | GET public snapshot pages |
| `…/{resource}/{id}` | GET one public value |
| `…/{resource}/{id}/history` | GET ascending committed public versions, including deletion records |
| `…/saved_queries` | POST create or update an owned absolute or rolling query definition |
| `…/saved_query_deletions` | POST delete an owned definition with a retained tombstone |
| `…/saved_queries/{id}/execute` | GET execute the stored query under current read authority |
| `…/things/{id}/properties/{property}` | GET authorized Runtime Property scalar |
| `…/things/{id}/properties/{property}/observe` | GET committed Property values as resumable SSE |
| `…/observations/{id}/raw`, `…/evidence/{id}/raw` | GET raw-permission native JSON downloads |
| `…/observations`, `…/enrollments`, `…/associations`, `…/materialisations`, `…/revocations` | POST corresponding domain mutation |
| `…/operations/{operation}` | GET same-principal durable receipt |
| `…/events` | GET bounded replay with a required cursor |
| `…/events/stream` | GET resumable SSE |

Scoped endpoints require a canonical bearer token in `Authorization`; POST
mutations additionally require a UUIDv4 `Idempotency-Key`. Analytics queries and
pages are read-only POST operations and do not use an idempotency key. No cookies or implicit
loopback authority are accepted. Success envelopes have exactly `schema`
(`wtr.response.v1`) and `data`; failures have `schema` and bounded `error` with
stable `code`/`path`. Mutation failures identify `not_committed`; a lost
acknowledgement returns HTTP 202 with an `unknown` receipt. Unexpected programming
failures return a redacted 500 and conservatively report unknown mutation outcome.
They are logged as a fixed failure message, never exception/request text.
Self-revocation may commit its own receipt; subsequent requests are denied.

Saved definitions use the same scope generation and idempotent receipt rules as
other mutations. The record persists its admitted `QuerySpec`, closed
visualization options, private owner and public owner pseudonym. Only the owner
can update or delete it. An absolute definition keeps schema
`wtr.saved-query.v1`. Supplying the exact rolling-window object produces schema
`wtr.saved-query.v2`; its positive duration is capped at 31 days and must equal
the stored template query range. Each execution replaces the template bounds
with `[host_now + 1 - duration, host_now + 1)`, re-admits the query and returns
those resolved bounds and their content identity. Copying or reading a
definition cannot widen authority: execution independently authenticates the
caller, checks `read` inside the query snapshot and applies the normal
concurrency, rate and deadline limits. Dashboard sharing policy remains outside
this contract.

API JSON replies use `application/json`. Raw downloads use
`application/vnd.wotex.tracker.observation+json` or
`application/vnd.wotex.tracker.evidence+json`, with an attachment filename.
They preserve native JSON types and canonical Base64 payloads. All responses
are `no-store` and `nosniff`. Media negotiation happens before mutations.
Authentication uses current host time in the store after queueing; credential
expiry is checked again immediately before commit. The optional clock on the
low-level store is explicit; the HTTP composition always supplies its host clock.

The durable event stream accepts exactly one `cursor` query argument or `Last-Event-ID` header.
Before headers, failures use the JSON error envelope. A ready frame has
`event: ready` and `{"schema":"wtr.stream.v1","cursor":"…"}` data. Domain frames
have `event: tracker`, encrypted cursor as the SSE `id`, and the complete
`wtr.event.v1` JSON data. Deduplicate the stable domain `data.id`, not the
encrypted transport token. Comment heartbeats carry no domain event. The stream
retains an access proof instead of the bearer token, rechecks authorization on
poll and before every event write, and closes on revocation, cursor expiry,
storage/write failure, shutdown or lifetime expiry. A resumed expired/invalid
cursor explicitly fails and requires resnapshot.

Beyond the earlier body/transaction/page ceilings, HTTP/1 request lines and
individual headers are limited to 8,192 bytes, with at most 32 headers. Four
acceptors allow 16 connections each (64 total), with no accept retry queue.
The 32 request and 16 stream reservations have monitored owners and hard
deadlines; owner death releases capacity. Transfer to a stream cancels the old
request deadline. The five-second request deadline begins after HTTP headers
are admitted; header reads separately have a five-second idle timeout. Socket
writes time out after five seconds. HTTP/2, WebSockets and response compression
are disabled. Transport framing/header failures can close/reject before the
versioned application envelope exists. There is no unbounded subscriber queue.

This slice exposes imported data, durable events, Runtime Property reads,
committed-value subscriptions and structured measurement queries, with a
standalone CLI and local bundled releases. Scanner and public rule-management
absence is explicit in capabilities. A listener being live does not qualify
those integrations or a production deployment.

The explicit host also supervises one internal `RuleScheduler`. Its bounded
host-only snapshot is available through `Server.rule_schedule/1`; it is not a
public HTTP rule-management endpoint. The scheduler restores heartbeat, battery
and transport-health state, maps the next receiver-time boundary to a local
monotonic timer, rechecks durable identity and commits the pure live transition.
Event intents may require separate physical authorization; no Action or
notification is dispatched.

## Structured measurement query contract

`POST …/analytics/query` requires `read` authority and the exact closed
`wtr.query-spec.v1` document. The query identifies one measurement and unit, one
to eight state series, an absolute from-inclusive/to-exclusive Unix-millisecond
window, accepted quality values, UTC bucket size, order and one of count,
minimum, maximum, mean or last aggregation. Windows are limited to 31 days and
1,000 points per series. Unknown fields, changed content identities, named
timezones and rolling windows fail before storage access.

The service opens a dedicated read-only connection and transaction, rechecks
current authority inside that transaction and pins the current scope generation.
Each requested series uses the indexed state-history prefix and extracts matching committed
`public.measurements` rows whose integer `observed_at` lies in the window. At
most 100,000 matching measurement rows are admitted across all series. A state
version containing the same requested measurement more than once, malformed
stored scalar metadata or an invented quality fails closed as unavailable
storage. `scanned_rows` counts extracted matching measurement rows supplied to
the evaluator; it is not a SQLite query-planner statistic.

Available rows must carry a native finite integer or number. Unavailable rows
must carry the tagged null scalar. Unit conflicts fail the query; unavailable
and rejected-quality rows are excluded and disclosed separately. The returned
`wtr.query-result.v1` binds the exact query, committed snapshot identity,
ordered series, bucket geometry, stable last-row ties and disclosure counts.
Empty buckets stay absent, which requires clients to render gaps. The core
result material is limited to 256 KiB and HTTP keeps its existing 4 MiB response
ceiling.

`POST …/analytics/pages` accepts exactly `wtr.query-page-request.v1`: the same
closed query, a page size from 1 through 1,000 and either null or the previous
encrypted cursor. The first response pins the current committed generation.
Each continuation binds the exact query identity, page size, next page index,
principal, scope and instance to that generation for seven days. Later writes
cannot enter later pages, while current read authority is checked again on every
request. Ascending and descending traversal use disjoint bucket windows in the
requested global order. Invalid, expired, foreign, exhausted or altered cursors
fail explicitly and never fall forward to a newer generation.

At most eight analytics queries execute concurrently, with two per principal and
sixteen starts per principal in each one-second window. Admission happens before
opening a query connection. Caller loss, store shutdown or the configured
five-second deadline repeatedly interrupts the SQLite progress/busy handlers
until the worker exits, then releases its reservation. Analytics connections are
separate from the serialized writer connection and open the already admitted
private database read-only.

This revision does not page query input, translate prompts or render graphs.
Saved absolute and rolling queries are part of this contract.
Reconnect/render/OS-native host-resource event families remain visible product
work rather than implied endpoint behavior.

The HTTP host supervises one volatile `OperationalHistory` collector by default.
It records the closed request, query, import-stage, store, forward-queue,
publication and store-resource events documented by
`OperationalTelemetry.contracts/0`. Measurements include integer microsecond
durations, query row counts, current pending queue depth/bytes and per-operation
processed/drop counts. Metadata is restricted to bounded stage, operation,
outcome, aggregation and resource atoms. No raw scope, principal, record,
position, prompt or payload becomes a metric label.

An explicitly started HTTP host samples its BEAM VM's total reported memory
bytes, process count and port count on startup and every 30 seconds. The closed
`runtime.sample` event has only the `beam` runtime label. These values cover the
whole VM, including other host instances; they are not OS RSS or per-tenant
measurements. The same volatile collector bounds and retains these samples.

Host code can page retained operational history with `OperationalHistory.page/2`.
The first page pins the collector epoch and current sequence high-water mark;
continuations carry that epoch, filter, limit, last sequence and high-water mark.
New samples do not enter a pinned traversal. A collector restart or altered
filter/limit returns `invalid_cursor`; pruning a needed sequence returns
`cursor_expired`. This is a host-only in-process interface, not an authenticated
HTTP endpoint or a durable analytics dataset.

Host code can read a coherent retained snapshot through
`Server.operational_history/2`; the snapshot carries a restart epoch, expires
samples after 15 minutes and is bounded to 2,048 entries unless the host chooses
smaller or explicitly admitted finite limits. This is an in-process host
contract, not an HTTP operation or a durable history promise. Loading the
package attaches no telemetry handler.

## Runtime Property read contract

The service builds an upstream `ExposedThing` from the committed TD and handlers
for its packaged scalar model. `readproperty` requires `read` authority; TD and
canonical state are fetched at the same immutable snapshot generation. Each
handler checks its deadline, availability, unit and declared scalar type.
Success is native `application/json` data constrained by the TD, with the decimal
`X-Wotex-Generation` header. Errors retain the API error envelope: unavailable
measurements are HTTP 503, expired execution deadlines HTTP 504, and missing
Properties HTTP 404. No numeric null, stale substitute or changed TD masks a
missing measurement. Physical mutation remains unsupported.

The supplied `HTTP.LoopbackClient` is an explicit local reader for Runtime
`ConsumedThing` through the upstream HTTP binding. It admits only the configured
numeric loopback HTTP origin, exact scope and Property GET path. The credential
is a separate immediate callback argument; the immutable plan/configuration do
not contain it. Mint **1.10.0** owns framing; the caller owns the socket, with no
connection process, DNS, proxy, pooling, redirect following or retry. Reads have
a maximum five-second deadline; header/status-line bytes are capped at 8 KiB,
header count at 32, body at 1 MiB, each reduced by smaller binding limits.
All completion/failure paths close the connection; caller death closes the owned
socket. Remote client qualification and general JSON Schema instance validation remain
separate concerns.

## Runtime Property observation contract

Materialisation adds `observable: true` and combined `observeproperty` /
`unobserveproperty` SSE Forms only through explicit host delivery evidence. Each
transport claim binds the readable capability's lineage, source observation,
profile/decoder revisions, exact Form and deployment revision. Its semantics are
**committed values**: a newly materialised Thing state is a sample. Import or
reassociation alone does not change that state. This declares host delivery, not
a physical device notification capability.

`GET …/things/{id}/properties/{property}/observe` requires current `read` authority.
Without a cursor it obtains TD, state and event high-water mark in one snapshot,
dispatches upstream Runtime `observeproperty`, then follows matching committed
`thing.changed` events. Reads during replay use each event's immutable generation.
A cursor resumes after the acknowledged sample; supply at most one `cursor`
query argument or `Last-Event-ID`. Property cursors are encrypted and bound to
instance, principal, scope, Thing and Property; event/history cursors cannot be
substituted. Seven-day retention and current authorization still apply.

Each SSE frame has native JSON scalar `data`, encrypted cursor `id`, and stable
`event` metadata: `property:snapshot:<generation>:<generation>` initially, or
`property:event:<event-id>:<generation>` for a committed update. Deduplicate using
the stable event metadata within this Thing/Property; encrypted cursors can differ
on replay. There is no Tracker envelope around the scalar on the wire. Comments
are heartbeats. Repeated equal values remain distinct committed samples.

An unavailable initial sample returns 503. An availability gap during replay
closes delivery after preceding valid samples; it is neither skipped nor replaced
with null. Resume at that gap returns 503. To continue after recovery, explicitly
request a fresh snapshot. Unsupported observation returns 501; missing Properties
return 404. Authorization, retention, storage, shutdown and write failures also
close streams. The same 16-stream instance budget and 300-second lifetime apply
as for durable events. Replay reads at most 25 events per batch and has a shared
five-second execution deadline; frames are bounded to 32 KiB.

The supplied `HTTP.LoopbackClient` implements the upstream binding subscription
port for this endpoint. A transient guard monitors owner and caller before
connection setup, with a five-second handshake ceiling and at most 100 ms for
numeric-loopback connect. After validated SSE headers, socket ownership transfers
to one monitored reader; the guard exits. Credentials are not retained by the
reader or opaque handle. Closing one handle leaves other readers alive. Owner
loss, finite lifetime (at most 300 seconds), transport/parse failure or an owner
queue of 32 messages closes the reader. There is no reconnect, retry or pool.

Mint 1.10.0 admits HTTP framing. The streaming parser admits BOM, UTF-8, CR/LF/CRLF,
comments, multiline data and event IDs across arbitrary byte splits under fixed
frame/line/batch bounds. Pending EOF data is discarded. Retry hints are preserved
as metadata without scheduling retries. Duplicate content-type/encoding fields,
compression, redirects and non-200 handshakes are rejected. These claims cover
the explicit numeric-loopback peer, not arbitrary remote deployment.

## Public resource history

`GET …/{resource}/{id}/history` covers observations, resolutions, evidence
summaries, enrollment, Things and canonical state. It requires current `read`
authority and returns only the same reviewed public projections as inspection.
It accepts `limit` (1–100, default 25) and an optional encrypted `cursor`; it
accepts no arbitrary SQL, field expression or private evidence filter.

Versions are sorted by ascending committed generation. Each item has `id`,
`generation`, `deleted` and `value`. Deletion is explicit (`deleted: true`,
`value: null`), while earlier versions remain readable. A resource with no
retained versions returns `not_found`. This endpoint does not itself delete or
alter resources. Schema 2 retains versions within the fixed database/table
capacity; it does not silently purge historical records.

The response has `items`, snapshot `generation`, optional next `cursor` and
`stream_cursor`. The next cursor seals resource, ID, snapshot, position, page
size and the existing instance/principal/scope binding for up to seven days.
It cannot be reused for another resource, ID, page size or endpoint. Invalid or
expired cursors fail explicitly. Every page rechecks current authorization
inside its SQLite snapshot. Later commits cannot enter an in-progress page set.
The stream cursor starts after the event high-water mark in that same snapshot;
event retention/replay rules remain in force. History responses share the 4 MiB
ceiling: reduce the requested page size on `response_too_large`.

## Source references

The selected driver and its direct API are described by the
[Exqlite 0.40.0 package](https://hex.pm/packages/exqlite/0.40.0) and
[driver documentation](https://exqlite.hexdocs.pm/0.40.0/Exqlite.Sqlite3.html).
Native source/version and executed platform evidence are recorded with each
acceptance batch. Full-disk tests use SQLite's real page ceiling as well as
injected commit boundaries; these are not physical power-cut tests.

The listener options follow the pinned
[Bandit source contract](https://hex.pm/packages/bandit/1.12.5/files/lib/bandit.ex),
[Plug connection contract](https://hex.pm/packages/plug/1.20.3/files/lib/plug/conn.ex)
and [Thousand Island connection limits](https://thousand-island.hexdocs.pm/1.5.0/ThousandIsland.html).
The OpenAPI audit and exchange validator are development tools, not service
runtime processes.
