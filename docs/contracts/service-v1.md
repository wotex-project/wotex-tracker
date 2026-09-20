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

Schema version 8 is created transactionally using `PRAGMA user_version`.
Version 1 upgrades through the forward-queue, rule-state, rule-history,
rule-event projection and alert schemas in the same startup transaction; later
versions start at their next step. The version 3 step reassigns existing rule versions
from the public asset `state` record kind to the private `rules` kind. The
version 4 step removes private capture, evidence, sample, fact and decision
references from stored public `tracker.event` documents; rule event intents keep
their complete private copy. The version 5 step backfills one unacknowledged
alert record for every existing rule event intent, identical to a newly written
alert. The version 6 step sets each alert's `thing_id` to the Thing of a service
definition with the alert's rule kind and ID, or null when none exists. Other scopes, operations, observations, events,
records, publications and queue items remain unchanged. The version 7 step adds
the bounded access-audit and per-scope coverage metadata without manufacturing
historical entries. Unknown newer schemas
fail startup. Migrations may never silently reset data.
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

`operations` and `GET …/operations` page, under `read`, the caller's own
unexpired receipts in the scope newest first by commit generation and operation
ID, each with its recording and expiry times; the cursor binds the first page's
generation, principal and page size. Clients use it to find recent work after
losing an operation reference.

Operation outcomes are `not_committed`, `committed` (with generation and separate
publication status), or `unknown`. A lost reply is unknown; clients query the
same operation identity and never automatically retry a physical Action.
Committed results are retained for seven days of explicit receiver time;
expired keys remain tombstones and return `operation_expired`. Expiry cannot
silently permit re-execution before a disclosed scope deletion. Event cursors expire after seven days; a cursor
outside retained history requires an explicit resnapshot. The first store
retains evidence/history and expired tombstones until administrator deletion or
configured whole-scope inactivity deletion; it rejects at capacity rather than
silently deleting linked evidence. Backup erasure remains separate operator work.

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
writes the canonical rule state, immutable rule history, deduplicated event
intent and public event at one scope generation. Rule history uses the `rules`
record kind, so public asset `state` pages, reads and history never return it. An exact retry returns the
original generation. A stale prior identity or a reused event ID with different
content conflicts without a partial write. Live event intents retain that a
physical Action still needs separate authorization; replay event intents retain
that dispatch is prohibited. The current port does not schedule evaluation,
deliver notifications or expose rule mutation over HTTP. Current rule status is
read-only through the reviewed `rules` projection below.

The public `tracker.event` copy is a reviewed projection. It keeps the event
ID, kind, reason, rule and policy identities and revisions, statuses, event and
evaluation times, trip and fence context, candidate route IDs and crossing
disclosures. It omits caller capture IDs, evidence IDs and digests of private
observations, samples, bundles, facts and transport decisions. Those references
remain only in the privileged rule event intent.

Event-only rules use the same intent and public-event tables without manufacturing
canonical state. The prepared host value retains complete closed inputs and the
pure result, re-evaluates them during admission, and binds its own identity. A new
event ID advances the scope and writes both rows atomically. An exact event retry
with the same mode/effect returns the original generation; changed content or
live/replay effect metadata conflicts. Inferred geofence crossings and suspicious
movement alarms use this path. A prepared authorized `Update` may instead stage
up to eight independently revalidated event-only intents. Their private intents,
reviewed events and alerts share the triggering mutation's generation and commit
or roll back with its records and state transitions. Duplicate stable intents do
not create another event or alert; a same-ID content or effect collision aborts
the entire mutation.

## Arming state

`Service.set_arming/6` and `POST …/arming` require `admin`, a UUIDv4 operation
ID and exactly `thing_id`, `status` (`armed` or `disarmed`) and
`expected_generation`. The Thing must exist at that generation. A commit writes
one `wtr.arming.v1` current-state record and `arming.changed` event under the
ordinary conditional mutation and replay contract. Unenrollment tombstones the
current arming record in the same transaction as the Thing.

The private record contains an exact `asset.armed` `PolicyFact` backed by a
closed, service-authored administrative-operation evidence bundle. It records
administrative intent; it does not claim a device observation, device contact or
physical Action. `GET …/arming/{thing_id}` restores that full fact before
returning the closed public state with its commit-derived revision, change time
and pseudonymous actor. Operation, observation, evidence, bundle and fact
identities never enter the public projection. This fact is the durable arming
input for suspicious-movement orchestration. The arming mutation reevaluates
every exact live suspicious binding for the Thing against its staged fact,
matching motion state and owner-presence fact. A true result stages its intent and
alert in the same transaction. It sends no notification.

## Owner-presence evidence

`Service.admit_owner_presence/6` and `POST …/owner_presence` require `admin`, a
UUIDv4 operation ID and exactly `thing_id`, a complete serialized `PolicyFact`
and `expected_generation`. The service restores the complete closed bundle and
requires exact or strong identity evidence whose predicate is `owner.present`
and whose association is the enrolled Thing. It does not manufacture absence
from missing or silent radio evidence.

A new fact must have a receiver observation time strictly later than the current
fact. Older and same-time conflicting evidence fails with `conflict`. A commit
stores the private fact and a reviewed `wtr.owner-presence.v1` projection in one
conditional transaction. Public list/get/history disclose only present, absent
or unknown, observation and admission times, a commit-derived revision and a
scope pseudonym of the admitting actor. Observation, evidence, bundle and fact
identities remain private. Unenrollment tombstones current owner-presence state.
Admission reevaluates exact live suspicious bindings against the staged fact and
atomically records any true result; it sends no notification.

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
`credentials` and `GET …/credentials` require `admin` and list, in credential ID
order, every configured credential granting a permission in the scope: its ID,
principal, that scope's sorted permissions, expiry, `current` flag and
`status` (`revoked`, `expired` at host time, or `active`). A revocation reports
its time, acting principal and generation, read at the current committed
generation. Token digests, secret keys and other scopes' grants are never
returned, and a revocation of an ID no longer configured is not listed.

Every successful facade authorization and explicit stream-delivery
reauthorization appends a durable access-audit entry before returning authority.
Entries contain only scope, configured credential ID, principal, required
permission, a closed service activity and receiver time; they omit bearer
material, proofs, request bodies and resource identifiers. The audit is separate
from domain generations and retains at most 10,000 entries per scope for 30 days.
Expiry or capacity removal sets a durable truncation marker. Administrator-only
pages are newest first, bind an encrypted cursor to the first page's sequence
snapshot and disclose the coverage start, bounds and truncation state. Failed
authentication and denied grants yield no successful-access entry.

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

Public state always contains bounded `measurements` and `positions` arrays. Each
position is the closed `wtr.position-public.v1` projection of one admitted
decoder claim: tagged latitude/longitude, altitude, speed, horizontal accuracy,
fix/receiver times, declared source, accuracy kind, fix-clock qualification,
availability and quality. It intentionally omits raw source fields, source units,
conversion revision, receiver observation ID and stable evidence/bundle
identities. Those values remain in the authorized raw evidence export. An empty
array means the decoded message supplied no position; it does not mean `(0, 0)`.

The default service configuration loads the packaged Ruuvi profile, decoder and
environmental model. An explicit host configuration may instead supply one
admitted catalogue, one model used by every profile in that catalogue, and
exactly one trusted unary callback per referenced decoder revision. Missing,
extra, duplicate, non-callable or model-incompatible entries fail service
construction. Profile resolution still chooses only inert revision values; wire
content never supplies callback code or a module name.

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
| `unenroll` | `admin`, plus `enroll` for enrollment, Thing and state records | `thing_id`, `expected_generation` |

Successful imports return `data.observation_id`; enrollment returns
`data.thing_id`; association returns that Thing ID, the selected public
`observation_id` and a new `association_id`; materialisation returns the Thing ID
and `materialisation_id`. Unenrollment returns the Thing ID, `action: "unenrolled"`
and the removed definition IDs in `policy_ids`.
Generated IDs are stored in the atomic operation receipt. After authentication
and request admission, exact replay returns that receipt before consulting a
new catalogue or model. A new request still checks its generation and authority
inside the final write transaction. Known preparation failures are
`not_committed`; only uncertainty after attempting a write yields `unknown`.

Unenrollment reads the enrollment, Thing, state and live rule definitions at the
request's exact generation. It writes deletion tombstones for the enrollment and,
when present, the Thing and its current state, plus every live definition bound
to the Thing, and publishes `enrollment.changed`, `thing.changed` when a Thing
existed and `policy.changed` with `deleted` for each definition. Deleted
definitions stop scheduling; rule status and history, alerts, observations,
private evidence and record history are retained, so this is not data erasure.
An open Property observation for the Thing closes at its next commit. No
publication intent or physical Action is created, and a removed Thing cannot be
materialised, given definitions or unenrolled again.

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
`enrollments`, `things`, `saved_queries`, `rules`, `policies`, `alerts`,
`arming` and `owner_presence`. Lists accept only `limit` (default
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

## HTTP and stream contract 1.38.0

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
| `/api/v1/scopes/{scope}/health/ready` | GET authenticated writable-store check reporting store schema `8` |
| `/api/v1/scopes/{scope}/access` | GET the current credential's non-secret ID, principal, exact requested-scope permissions and expiry after current read authorization |
| `/api/v1/scopes/{scope}/access_audit` | GET an administrator-only, snapshot-bound page of successful authorization decisions with explicit retention/capacity disclosure |
| `/api/v1/scopes/{scope}/privacy` | GET administrator-only exact retained primary-store counts, preservation rules, last deletion marker and limits of the deletion claim |
| `/api/v1/scopes/{scope}/domain_data_deletions` | POST generation-checked, explicitly confirmed deletion of all retained domain data in this scope while preserving revocations and the access audit |
| `/api/v1/scopes/{scope}/capabilities` | GET explicit available/unsupported/unconfigured/configured status; cellular is `configured` only when the composing host supervises its admitted listener, and notification delivery is `configured` only when it supervises an admitted dispatcher. These are composition states, not physical readiness or delivery receipts. Rules report `heartbeat_battery_motion_geofence_suspicious_movement_definitions`, route and trip history advertise their paging contracts, trip summaries advertise bounded gap-honest reconstruction, arming reports an explicit administrative fact, and owner presence reports closed evidence-fact admission |
| `…/analytics/query` | POST one read-only structured measurement query against a committed snapshot |
| `…/analytics/pages` | POST one snapshot-pinned bucket page with an encrypted continuation |
| `…/routes/pages` | POST one snapshot-pinned, gap-honest retained route page with an encrypted continuation |
| `…/observations`, `…/resolutions`, `…/evidence`, `…/state`, `…/enrollments`, `…/things`, `…/saved_queries`, `…/rules`, `…/policies`, `…/alerts`, `…/arming`, `…/owner_presence` | GET public snapshot pages |
| `…/{resource}/{id}` | GET one public value |
| `…/{resource}/{id}/history` | GET ascending committed public versions, including deletion records |
| `…/saved_queries` | POST create or update an owned absolute or rolling query definition |
| `…/saved_query_deletions` | POST delete an owned definition with a retained tombstone |
| `…/saved_queries/{id}/execute` | GET execute the stored query under current read authority |
| `…/policies` | POST create or update a heartbeat, battery, motion, geofence or suspicious-movement rule definition for one Thing |
| `…/policy_deletions` | POST delete a rule definition with a retained tombstone |
| `…/alert_acknowledgements` | POST acknowledge one live rule alert once |
| `…/arming` | POST commit an explicit armed or disarmed administrative fact for one enrolled Thing |
| `…/owner_presence` | POST admit a complete exact or strong `owner.present` fact for one enrolled Thing |
| `…/unenrollments` | POST remove one enrolled asset and its rule definitions from current views |
| `…/credentials` | GET the administrator audit of this scope's configured credentials, grants, expiry and revocation |
| `…/things/{id}/policies` | GET the at most eight live rule definitions bound to one Thing |
| `…/things/{id}/alerts` | GET newest-first alerts of the rules defined for one Thing |
| `…/things/{id}/trips` | GET snapshot-pinned newest-first trip lifecycle events for one Thing |
| `…/things/{id}/trips/{trip}` | GET one bounded completed-trip distance summary reconstructed from retained private evidence |
| `…/things/{id}/rules` | GET the committed status of every rule defined for one Thing at one snapshot |
| `…/things/{id}/properties/{property}` | GET authorized Runtime Property scalar |
| `…/things/{id}/properties/{property}/observe` | GET committed Property values as resumable SSE |
| `…/observations/{id}/raw`, `…/evidence/{id}/raw` | GET raw-permission native JSON downloads |
| `…/observations`, `…/enrollments`, `…/associations`, `…/materialisations`, `…/revocations` | POST corresponding domain mutation |
| `…/operations` | GET the caller's own unexpired receipts, newest first |
| `…/operations/{operation}` | GET same-principal durable receipt |
| `…/events` | GET bounded replay with a required cursor |
| `…/events/stream` | GET resumable SSE |

Scoped endpoints require a canonical bearer token in `Authorization`; POST
mutations additionally require a UUIDv4 `Idempotency-Key`. Analytics queries,
analytics pages and route pages are read-only POST operations and do not use an
idempotency key. No cookies or implicit
loopback authority are accepted. Success envelopes have exactly `schema`
(`wtr.response.v1`) and `data`; failures have `schema` and bounded `error` with
stable `code`/`path`. Mutation failures identify `not_committed`; a lost
acknowledgement returns HTTP 202 with an `unknown` receipt. Unexpected programming
failures return a redacted 500 and conservatively report unknown mutation outcome.
They are logged as a fixed failure message, never exception/request text.
Self-revocation may commit its own receipt; subsequent requests are denied.

The scope deletion operation removes observations, every non-access domain
record version, events, publication intents, queued deliveries, rule state and
event intents, and prior operation receipts in one immediate transaction. It
then advances the scope generation and retains only a minimal deletion marker,
public deletion event and the caller-recoverable receipt. Exact retry returns
that receipt; stale generation conflicts; failure before commit leaves every row
intact; loss after commit resolves through ordinary operation lookup. Existing
event cursors cannot cross the erased sequence and fail explicitly. Durable
credential revocations and the separately bounded successful-access audit remain
so deletion cannot reactivate access or erase its security record.

The optional host `privacy_policy.domain_inactivity_retention_ms` accepts one
minute through one year. When configured, the same complete managed-domain
deletion runs atomically at the exact boundary after the last domain mutation.
Every authorization enforces the boundary before reading or writing, and the
store also checks once per minute without waiting for access. Successful reads
and access-audit entries do not extend the interval. Automatic deletion records
the `automatic_inactivity` cause in its marker and public event but creates no
fictional administrator receipt; a later mutation starts a new interval. The
default remains administrator deletion only.

The managed SQLite connection enables secure deletion of freed cells. This is a
primary-store logical deletion contract, not a claim about every historical
physical byte: concurrent readers can defer WAL reclamation. Pre-existing
backups, offline exports and already-remote publications are outside the managed
store and are reported as not deleted. Operators remain responsible for their
separate expiry and erasure policies.

The access projection requires the same current `read` authority as the shared
application. Its `wtr.access.v1` document contains only the current configured
credential ID, principal, requested scope, sorted exact grants for that scope and
expiry. It never serializes the bearer token, token digest, access proof, secret
key or another scope's grants. A durable revocation or expiry therefore denies
the projection instead of returning stale authority.

The shared presentation package has a versioned remote client for this HTTP
surface. Its closed action-to-path mapping cannot select an arbitrary host,
method or route. It sends bearer material only in the Authorization header,
requires exact response envelopes and media types, bounds request and response
material, follows no redirect and performs no automatic retry. An ambiguous
mutation response remains `unknown` under the original operation identity;
receipt lookup is the recovery mechanism. The adapter retains no credential or
canonical state and accepts plaintext only on explicitly enabled numeric
loopback origins.

Saved definitions use the same scope generation and idempotent receipt rules as
other mutations. The record persists its admitted `QuerySpec`, closed
visualization options, private owner and public owner pseudonym. Only the owner
can update or delete it. An absolute definition keeps schema
`wtr.saved-query.v1`. Supplying the exact rolling-window object produces schema
`wtr.saved-query.v2`; its positive duration is capped at 31 days and must equal
the stored template query range. Each execution replaces the template bounds
with `[host_now + 1 - duration, host_now + 1)`, re-admits the query and returns
those resolved bounds and their content identity. A snapshot window
`{"kind":"snapshot","generation","result_identity"}` produces schema
`wtr.saved-query.v3`, an incident snapshot. Its generation must equal the save's
`expected_generation`; before storing, the service reruns the absolute query at
that generation and conflicts unless the result has `result_identity`, so the
snapshot is exactly the result the client displayed. Each execution reruns the
query at the pinned generation and returns `revision_mismatch` if the retained
data no longer reproduces that identity. Copying or reading a
definition cannot widen authority: execution independently authenticates the
caller, checks `read` inside the query snapshot and applies the normal
concurrency, rate and deadline limits. Dashboard sharing policy remains outside
this contract.
Save and delete receipts identify the affected definition in `data.query_id` and
the committed mutation in `data.action` (`saved` or `deleted`). An operation
lookup can therefore distinguish an edit from a deletion after a lost reply.

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
individual headers are limited to 8,192 bytes, with at most four unique query
pairs and 32 headers. Four
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

An optional explicit `notification_dispatcher` host configuration supervises a
bounded provider-neutral delivery worker after the store. It claims only APNs
items carrying `wtr.notification-reference.v1`, resolves the exact encrypted
endpoint revision and rechecks the retained administrator credential against
current grants, expiry and durable revocation before each provider call. The
adapter receives only the private endpoint target and opaque alert reference.
Provider acceptance completes the queue item at application acknowledgement;
retryable, crashing and malformed outcomes leave it pending. Missing, rotated or
revoked endpoints and permanent provider rejection are separate terminal reasons.
An invalid-token response tombstones only the still-matching endpoint revision.
`Server.notification_dispatcher/1` exposes bounded host-only counts, never tokens,
targets or payloads. The host supplies the provider adapter explicitly; this
contract neither selects APNs credentials nor equates provider acceptance with OS
delivery or a user read.

The standalone host may select this composition with a separate private
`WOTEX_TRACKER_APNS_CONFIG` file. The Nerves appliance uses the same document at
the fixed root-bound `/root/tracker/apns.json` path only when its closed build
choice is enabled. The exact `wtr.apns-host.v1` document admits an Apple team ID,
key ID, unencrypted P-256 key contents, sorted closed bundle-topic and service-
scope sets, generic title/body copy, provider timeout, worker polling and retry
intervals, batch ceiling and dispatch timeout. The same 0600 regular-file, 0700
parent, absolute-path, no-symlink and 64 KiB rules as the main host configuration
apply. Missing disabled configuration starts no dispatcher; a selected but
missing, malformed, unsafe or open document fails startup. The authenticated
capability status is `notification_delivery: configured` only for the admitted
supervised composition, and `unconfigured` otherwise. The Nerves appliance also
requires its current runtime to report synchronized time before opening storage
when this provider-token composition is selected; a last-known clock estimate is
not sufficient for the time-bound APNs JWT.

`APNsAdapter` is the concrete opt-in token-authenticated provider boundary. Its
constructor admits one Apple team ID, key ID, unencrypted P-256 private-key value,
closed sorted topic set, generic notification copy, timeout and transport. The
opaque configuration's inspection omits the decoded private key. No path,
environment variable or application setting is read. Each delivery creates an
ES256 JWT with current whole-second `iat`, chooses only Apple's sandbox or
production host from the retained endpoint environment and issues one bounded
HTTP/2-over-verified-TLS POST through Mint. The request declares topic, alert
push type, priority 10, zero expiry and a UUID request ID; its JSON body contains
only generic copy and the `wtr.notification-reference.v1` opaque event reference.
The body and response body are limited to 4,096 bytes, response headers to 32 and
8,192 bytes, and the whole operation to at most 30 seconds. Transport failures,
5xx responses and 429 remain retryable; 400/410 invalid-device reasons request
conditional endpoint removal; other 4xx responses are permanent rejection.
These mappings follow Apple's [request](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns),
[token authentication](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns)
and [response](https://developer.apple.com/documentation/usernotifications/handling-notification-responses-from-apns)
contracts. A real signed app, provisioned device and provider key remain required
to establish physical delivery and tap evidence.

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

## Retained route page contract

`POST …/routes/pages` requires `read` authority and exactly one
`wtr.route-page-request.v1` document. It names a UUID Thing, a
from-inclusive/to-exclusive Unix-millisecond window, `trusted_fix` or explicit
`trusted_fix_or_receiver` event-time policy, a nonempty unique subset of
`valid`/`suspect` qualities, positive time/distance gap limits, a page size from
1 through 100 and a nullable cursor. Unknown fields and malformed policies fail
before retained evidence is read.

The first request pins the current scope generation and pages the Thing's private
evidence versions in ascending generation order. Each item must reconstruct one
source observation and a valid complete evidence bundle. Exactly one position is
evaluated as a `PositionSample`; no position becomes `missing_position`, and
multiple positions become `ambiguous_positions`. The latter two are public
exclusions, not silently selected or discarded samples. Every private observation
fetch rechecks current authority at the pinned generation. Damaged retained
evidence fails the whole page as unavailable storage.

The service applies the pure route replay policy to qualified samples and then
splits its segments around any in-window exclusion. The public
`wtr.route-page.v1` response uses tagged scalars and scope pseudonyms for point,
rejection and exclusion IDs. Raw evidence, bundle, observation and sample IDs
never cross the boundary. It reports the pinned generation, exact materialisation
history interval, requested window, replay counts, breaks/rejections/exclusions,
content identity and nullable next cursor. The half-open requested window filters
samples and exclusions but does not change the retained page's record count.

A continuation binds the Thing, exact request identity, page size, generation,
next evidence version, principal, scope and service instance for seven days.
Later writes cannot enter the traversal and current authority is checked on every
page. Each response declares `page_local_only` continuity: a client must never
join a page's final segment to the next page's first segment. A larger page or a
new request is required when cross-record continuity matters.

This revision does not page query input, translate prompts or render graphs.
Saved absolute and rolling queries are part of this contract.
An explicitly enabled browser host bridges its LiveView render spans into the
closed `render.stop` event and its marked reconnect attempts into the closed
`connection.stop` event. The Nerves and standalone Linux service hosts emit a
closed `native.sample` event from procfs. Native resource families for other
operating systems remain visible product work rather than implied endpoint
behavior.

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

The Nerves host and standalone Linux service host each supervise a separate
sampler after their service. On startup and every 30 seconds it reads only
`/proc/meminfo`, `/proc/self/status` and `/proc/loadavg`, each bounded to 65,536
bytes. A sample is admitted only when it contains system available memory bytes,
the BEAM OS-process RSS bytes and one-minute load multiplied by 1,000 as
nonnegative integers. Missing, malformed or oversized input emits no partial
sample and cannot affect the service. The closed `native.sample` metadata uses
the exact `nerves` or `service` surface and `linux_procfs` source; paths, scope,
device and process identifiers are absent. A non-Linux standalone host does not
start this adapter.

The optional browser host installs a render-and-connection handler before
starting its endpoint. It records root Tracker LiveView render duration in
integer microseconds with only `browser` surface and `ok` or `unavailable`
outcome. Component renders and other LiveViews are excluded. After that
LiveSocket has opened once, its connection parameters mark later attempts as
reconnects; a page load creates a new LiveSocket and remains an initial
connection. The host accepts marked events only for its exact endpoint and
records integer microsecond duration with `browser` surface, `reconnect` kind
and `ok` or `unavailable` outcome. Socket parameters, route, asset and exception
metadata never enter the collector. A headless artifact installs neither
browser handler.

Host code can page retained operational history with `OperationalHistory.page/2`.
The first page pins the collector epoch and current sequence high-water mark;
continuations carry that epoch, filter, limit, last sequence and high-water mark.
New samples do not enter a pinned traversal. A collector restart or altered
filter/limit returns `invalid_cursor`; pruning a needed sequence returns
`cursor_expired`. This is a host-only in-process interface, not an authenticated
HTTP endpoint or a durable analytics dataset.

`OperationalHistory.window_page/2` combines that exact page with a bounded graph
projection from the same retained snapshot. A first read accepts a closed event
filter, a page limit and a positive window no longer than 15 minutes. It pins
the collector epoch, absolute from-exclusive/to-inclusive UTC bounds and current
sequence high-water mark. Its cursor additionally binds the window duration and
the first retained sequence needed to reproduce the projection. A continuation
with changed inputs or a different epoch is invalid; expiry of that first sample
is explicit. New samples never enter the pinned window.

The response carries up to 25 exact samples for browser table navigation and at
most the latest 1,000 matching samples for the graph. `omitted_before` reports
the exact number of earlier matching samples excluded from the graph projection;
those samples remain reachable in the table pages until retention expiry. This
is a presentation budget, not undisclosed downsampling, and no line or inferred
value is part of the collector contract.

Host code can read a coherent retained snapshot through
`Server.operational_history/2`; the snapshot carries a restart epoch, expires
samples after 15 minutes and is bounded to 2,048 entries unless the host chooses
smaller or explicitly admitted finite limits. This is an in-process host
contract, not an HTTP operation or a durable history promise. Loading the
package attaches no telemetry handler.

`OperationalHistory.export_batch/2` reads ascending sanitized samples after an
optional `wtr.operational-checkpoint.v1`. Every response is a bounded
`wtr.operational-export.v1` document carrying the collector epoch, current
high-water sequence, samples, a next checkpoint and whether more retained rows
are immediately available. The first read is labelled `snapshot`. A checkpoint
behind the earliest retained sequence yields `retention_gap` with the exact
number lost; a changed epoch yields `collector_restart` with unknowable loss.
Malformed or future checkpoints are invalid.

`OperationalExporter` is an optional explicitly started process over that read.
It holds one batch, calls a host-supplied `OperationalExportAdapter` outside the
collector with a finite deadline and advances only after `:ok`. Rejection,
unavailability, adapter crash and timeout cause retry from the acknowledged checkpoint.
Adapter context is omitted from inspection. The destination must deduplicate by
epoch/checkpoint and owns credentials, authorization, transport and its remote
retention/query policy. No exporter is started by package loading or by the
default HTTP host.

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
not contain it. Mint **1.10.1** owns framing; the caller owns the socket, with no
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

Mint 1.10.1 admits HTTP framing. The streaming parser admits BOM, UTF-8, CR/LF/CRLF,
comments, multiline data and event IDs across arbitrary byte splits under fixed
frame/line/batch bounds. Pending EOF data is discarded. Retry hints are preserved
as metadata without scheduling retries. Duplicate content-type/encoding fields,
compression, redirects and non-200 handshakes are rejected. These claims cover
the explicit numeric-loopback peer, not arbitrary remote deployment.

## Public resource history

`GET …/{resource}/{id}/history` covers observations, resolutions, evidence
summaries, enrollment, Things, canonical state, saved queries, rule status and
rule definitions. It requires current `read`
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

## Rule definitions

`policies` holds administrator-managed rule definitions. `save_policy` and
`delete_policy` require `admin`, a UUIDv4 operation ID and the expected scope
generation, and use the ordinary receipt, replay and unknown-outcome contract.
Reads, pages and history use `read`.

A save request has exactly `id`, `kind`, `thing_id`, `parameters` and
`expected_generation`. The ID matches `^[a-z0-9][a-z0-9-]{0,62}$`, so it can also
form a `{kind}:{id}` rule status identifier. `kind` is `heartbeat`, `battery`,
`motion`, `geofence` or `suspicious_movement`:

| Kind | Exact parameters |
| --- | --- |
| `heartbeat` | `maximum_silence_ms`, `future_skew_ms` |
| `battery` | `measurement_kind`, `unit`, `low_threshold`, `clear_threshold`, `maximum_age_ms`, `future_skew_ms`, `accept_suspect` |
| `motion` | `event_time`, `future_skew_ms`, `late_window_ms`, `sequence`, moving/stationary speed and distance thresholds, `max_plausible_speed_m_s`, `max_gap_ms`, `uncertainty`, `minimum_movement_ms`, `minimum_stop_ms` |
| `geofence` | closed circle or polygon `shape`, `boundary`, `uncertainty`, `event_time`, `future_skew_ms`, `late_window_ms`, `sequence`, `max_transition_gap_ms` |
| `suspicious_movement` | `motion_rule_id`, `maximum_fact_age_ms`, `future_skew_ms`, `owner_unknown_as_absent` |

Durations are bounded integer milliseconds; thresholds are finite numbers and
the low threshold must be below the clear threshold. Motion thresholds preserve
the pure classifier's stationary/moving hysteresis and plausible-speed limits.
Geofence geometry is admitted through the pure bounded geometry constructor. The service
assigns the policy revision as the decimal generation the definition commits at,
constructs the pure policy and stores its content identity. The request cannot
choose a revision, identity, owner, timestamp or evaluation mode.

Preparation reads the requested snapshot. The Thing must exist there. A battery
definition must name a declared numeric Thing Property with exactly the same
unit; otherwise it returns `unsupported` rather than accepting a rule that could
never qualify evidence. An existing ID keeps its kind and Thing; changing either
conflicts. A deleted ID can be defined again only for its first version's kind
and Thing, so one rule history never mixes evidence from different assets. One
Thing can have at most eight live definitions; editing an existing one remains
allowed at that limit, and a ninth returns `capacity_exceeded`.

A suspicious-movement definition must reference a motion definition for the
same Thing, and cannot reference its own ID. Preparation restores that motion
definition at the requested generation and embeds the exact motion policy in the
private suspicious policy document. The reviewed public definition discloses
only the reference ID, fact timing and unknown-presence choice, plus the outer
policy identity. It never exposes the nested policy or the fixed `asset.armed`
and `owner.present` predicate names.

The stored record retains the acting principal privately and projects
`wtr.rule-definition.v1` with ID, kind, Thing, revision, policy identity, exact
parameters and creation/update times. A deletion is a tombstone; earlier versions
stay readable in history. Both mutations publish `policy.changed` with the ID and
`saved` or `deleted`. `thing_policies` and `GET …/things/{id}/policies` return, in
ID order and under `read`, the live definitions bound to one Thing at the current
snapshot with that generation; an unknown Thing has none. `thing_rules` and
`GET …/things/{id}/rules` return, under `read`, the reviewed status of each of
those definitions as `kind:id` items read at the definitions' generation, omitting
a definition without recorded status. Suspicious movement is event-only, so its
definition alone never manufactures a current rule-status row.

### Definition evaluation

Saving a definition evaluates it in the same transaction against the evidence
committed by the Thing's latest materialisation at the requested snapshot. The
stored claims and their single source observation are restored through the pure
constructors. A heartbeat rule consumes that receiver observation; a battery rule
consumes the declared measurement as a complete `MeasurementSample`. Motion and
geofence rules construct a complete `PositionSample` only when the bundle has
exactly one position claim. Zero or multiple claims leave them unchanged: source
selection is never implicit. A new rule establishes a baseline, and an edit
recomputes with the new revision. Saving a suspicious-movement definition binds
its private policy and evaluates any matching committed motion state, arming fact
and owner-presence fact in the same transaction.

Materialising a Thing evaluates every live definition bound to it against the
newly built observation and evidence bundle. The materialisation records, rule
state, rule history, event intents and public events commit at one generation or
not at all; replaying the same operation returns the original receipt without
another evaluation. Evaluation uses live mode and the service host time. Unchanged
results write nothing, a Thing evidence set without the declared battery
measurement leaves that rule unchanged, and a conflicting evidence identity fails
the mutation. Every recorded event intent still requires separate authorization
before any physical effect; no notification is sent.

Each materialisation, suspicious-definition save, arming change and
owner-presence admission also reevaluates all live suspicious definitions for
that Thing. The referenced live motion definition must still have the exact
identity embedded in the suspicious policy. Staged motion/fact/definition values
take precedence over the requested snapshot; missing inputs, stale facts,
non-true results and changed or deleted motion bindings produce no event. A true
result is converted to a revalidated event-only intent, public event and Thing
alert at the triggering generation. All triggering records, state transitions
and event rows commit or roll back together, while exact operation replay creates
no duplicate.

The rule scheduler continues to age heartbeat and battery state. A deleted
definition keeps its last status and history, is reported as retired to the host
scheduler, and is no longer scheduled or ticked. Saving the same binding again
reactivates it with a new revision. Imported observations alone never evaluate a
Thing's rules; they must first be explicitly associated and materialised.

## Rule alerts

Every recorded rule event intent writes a `wtr.alert.v1` record in the same
transaction and generation as the intent and its public event. Its ID is
`alert-`, the zero-padded difference between the maximum signed 64-bit
generation and the commit generation, `-` and the event ID, so ordinary ascending
ID pages list the newest alerts first. The alert carries the reviewed public
event, the rule kind and ID, live or replay mode, the physical-action dispatch
flag, the evaluation time, the commit generation and `acknowledgement: null`.
Its `thing_id` names the Thing of the service definition with the same rule kind
and ID, read in the writing transaction, so a definition saved in that commit
binds its own alerts. Definitions fix kind and Thing for an ID, so the binding
cannot change. Alerts of host-managed and event-only rules have `thing_id: null`.
List, get and history require `read`. `thing_alerts` and
`GET …/things/{id}/alerts` page the alerts bound to one Thing newest first under
`read`, with `limit` from 1 to 100 and a cursor bound to that Thing and page
size; an unknown Thing has none.

`Service.thing_trips/6` and `GET …/things/{id}/trips` apply the same current
`read` authorization and public alert projection but select only
`trip.started`, `trip.stopped` and `trip.interrupted` in the snapshot query.
The encrypted cursor binds the endpoint, principal, scope, service instance,
Thing, generation, effective-time window and page size for seven days. Optional
`from_at` and `to_at` Unix-millisecond bounds must be supplied together; the
lower bound is included and upper bound excluded. A continuation takes its
window only from the authenticated cursor. Later commits are excluded from
continuations, generic alert cursors cannot cross the boundary, and battery,
geofence or other alerts never consume the trip page limit. An unknown Thing
returns an empty page.

`Service.trip_summary/6` and `GET …/things/{id}/trips/{trip}` require current
`read` authority and operate in a dedicated SQLite read snapshot. They accept
only an immutable trip with exactly one retained start and one stop or
interruption bound to the requested Thing. The service restores the motion state
and exact policy committed with the start, reconstructs the retained position
cohort through the terminal event, and admits at most 100 exact samples. Only
adjacent segments proved moving contribute to the centre, lower and upper metre
totals; all other adjacent segments remain explicit exclusions and are never
bridged.

The public `wtr.trip-summary.v1` projection identifies the terminal event,
start-policy revision, completion status, distance bounds and complete public
segment ledger. Observation, evidence, bundle, sample and policy identities stay
inside the service. Active, unknown or incomplete trips return no final summary;
missing, ambiguous, corrupt or noncanonical cohorts fail explicitly, and a
larger cohort returns `capacity_exceeded` rather than truncating distance.

`acknowledge_alert` requires `admin`, a UUIDv4 operation ID and exactly
`alert_id` and `expected_generation`, with the ordinary receipt and replay
contract. Only a live, unacknowledged alert can be acknowledged; a replay alert
or a second acknowledgement conflicts. The new alert version records the
acknowledgement time and a scope pseudonym of the actor, keeps the principal
private and publishes `alert.acknowledged` with the alert ID. Acknowledgement
changes no rule state or definition, is not a notification receipt and never
authorizes or dispatches a physical Action.

## Public rule status

`rules` is a read-only public resource over committed rule history. Its IDs are
`{kind}:{rule_id}` for `battery`, `geofence`, `heartbeat`, `motion` and
`transport_degradation`. List, get and history use the ordinary snapshot page,
cursor and `read` authorization contract. Status changes only through a rule
definition mutation, a Thing materialisation or the host scheduler; there is no
direct rule-status write. Arming and alert acknowledgement are separate
resources and do not change rule state. Service capabilities
report `rules` as `heartbeat_battery_motion_geofence_suspicious_movement_definitions`.

Each `wtr.rule-status.v1` value first restores the stored document through its
pure state constructor. A document that fails restoration or names another rule
returns `storage_unavailable`, not a partial projection. The value contains the
rule ID, revision and content identity, the state identity, a closed status and
one object named by `kind`:

| Kind | Status | Kind object |
| --- | --- | --- |
| `heartbeat` | `current`, `overdue` | last receiver observation time, due and evaluation times, maximum silence |
| `battery` | `unknown`, `normal`, `low` | public measurement projection, observation and evaluation times, thresholds, freshness and suspect policy |
| `transport_degradation` | `healthy`, `degraded`, `unknown` | decision status/action, selected candidate ID, decision and evaluation times, healthy candidates and maximum age |
| `motion` | `unknown`, `stationary`, `moving` | pending status and start time, last received outcome, active trip ID/start/confirmation and dwell durations |
| `geofence` | `inside`, `outside`, `uncertain`, `unknown` | fence ID/revision/identity, membership reason and event time, last received outcome and transition gap |

Times, durations and numeric thresholds use the tagged scalar representation.
A geofence without a valid membership reports `unknown` with null reason and
time. The projection omits receiver observations, evidence and sample bundles,
source identifiers, coordinates, accuracy, distances and raw transport ledgers.
Those remain private evidence; the projection is not an authorization to read
them. Public events for rule transitions keep their existing event contract.

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
