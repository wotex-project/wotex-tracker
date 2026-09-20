# Tracker service components

Explicitly started service components live here. Loading this package starts no
Tracker listener or store. The pure `wotex_tracker` package has no dependency on
this package. The durable-store contract and current acceptance scope are in
the repository's `docs/contracts/service-v1.md`.

Development uses `WOTEX_PATH_DEPS=1 MIX_ENV=test mise exec -- mix check --no-retry`
from this directory. Production resolves normal package artifacts. The local
workspace switch is rejected in production.

The complete gate includes the separate-process HTTP/SSE consumer and the
OpenAPI contract audit. Both run on the declared Elixir/OTP toolchain; there is
no second language environment to install:

```sh
WOTEX_PATH_DEPS=1 MIX_ENV=test mise exec -- mix check --no-retry
```

`Wotex.Tracker.Service.new/1` takes an explicit `Store` handle, `Credentials`
value and public `base_url` origin. It loads the packaged RAWv2 catalogue and
environmental model. The host owns time, credential custody and supervision.
`Wotex.Tracker.Service.HostProvisioning.initialize/1` supplies a shared,
create-only seam for hosts that need to prepare the closed `wtr.host.v1`
document, private operator-token file and empty data directory. The caller gives
separate destination and runtime roots plus explicit expiry time. The operation
uses exclusive 0600 files and 0700 directories, never returns the bearer token,
never replaces an occupied path and starts no listener. It creates only a
loopback configuration; exposed/TLS deployment remains explicit host policy.
Every facade operation authenticates an ephemeral bearer token and exact scope.
`Service.access/4` and `GET …/access` return the current credential's non-secret
ID, principal, exact scope permissions and expiry after the ordinary durable
revocation check. Bearer material, its digest, the internal access proof and
grants for other scopes are never returned. This gives remote presentation hosts
the same explicit authority projection as an in-process UI adapter.
Every successful service authorization is also appended to a separate durable,
administrator-only audit without changing the scope's domain generation.
`Service.access_audit/5` and `GET …/access_audit` page a snapshot of credential
ID, principal, permission, closed activity and receiver time. Bearer material,
request bodies and resource identifiers are excluded. The audit retains at most
10,000 entries per scope for 30 days and reports its original coverage start and
whether retention or capacity has discarded older entries.
`Service.privacy/4` and `GET …/privacy` give an administrator exact counts for
the retained primary-store categories plus the consequences of deleting them.
`Service.delete_domain_data/6` and `POST …/domain_data_deletions` require the
current generation, a stable operation ID and the exact confirmation phrase.
One commit removes observations, non-access record versions, event history,
publication intents, queued deliveries, rule state/intents and prior receipts,
then records a minimal deletion marker, event and recoverable receipt at the
next generation. Durable credential revocations and the bounded access audit are
preserved. SQLite secure deletion is enabled for the managed store, but backups,
offline exports and already-remote publications are explicitly outside the
erase claim and remain operator-managed.
Hosts may configure `privacy_policy.domain_inactivity_retention_ms` from one
minute through one year. When enabled, any service authorization enforces the
exact boundary and the store also checks every minute without waiting for a
request. A quiet scope is deleted through the same atomic managed-store boundary
with an `automatic_inactivity` marker, but without inventing an administrator
operation receipt. Reads and access-audit writes do not extend domain lifetime;
any domain mutation starts a new inactivity interval. The policy is disabled by
default.
An exact six-field form may instead provide an admitted `catalogue`, one
compatible admitted `model`, and a bounded `decoders` list containing exactly
one trusted unary callback for every decoder revision referenced by that
catalogue. Extra, duplicate, missing or model-incompatible configuration fails
before the service is built; observations never select executable code.

`Wotex.Tracker.Service.Cellular.Ingress` is a separately started trusted-host
bridge for decoded Teltonika packets. Its finite configuration maps keyed IMEI
digests to private service credentials, scopes and operator device labels; raw
IMEIs are transient and are not retained in state or observations. The bridge
revalidates every frame, serializes admission, commits one byte-preserving
cellular observation per packet and derives a deterministic UUID operation ID
for reconnect reconciliation. Accepted and duplicate commits return full-record
ACK dispositions, known non-commits return zero-ACK dispositions and unknown
outcomes require connection close. The bridge owns no socket and supplies no
device-specific profile or authentication claim.

The facade supports imported observations, public inspection and paginated
snapshots, encrypted event cursors, privileged byte-preserving raw exports,
operator-confirmed enrollment and reassociation, materialisation, structured
measurement analytics, revocation and operation-status lookup. `Service.operations/5` and
`GET …/operations` page the caller's own recent receipts newest first. Mutations take a
lowercase UUIDv4 operation ID and a decimal-string
expected generation. The original committed receipt is replayed before new
profile/model work, including its generated Thing ID. Unknown outcomes require
receipt lookup; they do not authorize automatic physical Action retries.

Decoded normalized positions are retained in private evidence and projected into
public state as closed `wtr.position-public.v1` values. Coordinates, source,
quality, stated accuracy and qualified fix/receiver times are visible under the
ordinary scoped `read` authority. Raw source fields, source units, conversion
revision, receiver observation ID and evidence identities are omitted; authorized
raw evidence export retains them exactly. The packaged Ruuvi decoder produces an
empty position list.

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
commit compares the prior state identity and records canonical state, private
rule history, a stable event intent and its event at one scope generation. Rule
history is never listed as public asset `state`. Motion
and geofence state retain deduplicated registries of their complete
evidence-bound samples.
Exact retries are idempotent, stale writers conflict, and restart recovery reads
the native JSON state back through the pure constructor. Replay event intents
retain prohibited dispatch, while live event intents retain the need for separate
authorization.

`RuleScheduler` is a caller-owned bounded process for persisted heartbeat,
battery and transport-health time boundaries. It admits at most 1,024 rules,
refreshes at a finite interval and converts receiver Unix boundaries once to
local monotonic deadlines. It rereads the durable state before firing, ignores
stale timer tokens, rebuilds after restart and commits through the same atomic
rule transaction. The explicit HTTP `Server` supervises one scheduler by default
and exposes bounded host-only deadline metadata through
`Server.rule_schedule/1`. Package loading remains inert. Notification delivery
is disabled unless the host supplies an explicit dispatcher and provider adapter.

Stateless rule results use the same intent and public-event tables through
`RuleEvent`. Its crossing constructor restores complete fence, endpoint and
policy documents, while its suspicious-movement constructor restores the motion
state and both evidence-backed facts. Each re-evaluates the pure result before
commit. A new stable event advances the scope once; an exact retry returns the
original generation. The recorded mode and physical-action metadata cannot be
changed by replaying the same event identity through another mode. Trusted host
preparation can also stage these event-only intents inside an ordinary authorized
mutation; the triggering records, private intent, reviewed event and alert then
commit at one generation or all roll back.

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
`Service.unenroll/6` and `POST …/unenrollments` let an administrator remove one
enrolled asset: its enrollment, Thing, current state and rule definitions become
tombstones in one commit while history, evidence and alerts are retained.
`Service.credentials/4` and `GET …/credentials` give administrators an audit of
the scope's configured credentials, their grants, expiry and durable revocation,
without token digests.
Scanner and public rule management remain explicitly unsupported. Analytics is
reported as `structured_queries`, and rules as
`heartbeat_battery_motion_geofence_suspicious_movement_definitions`; retained route history is
reported as `snapshot_pinned_gap_honest_pages`. Owner presence is reported as
closed evidence-fact admission, never as an inferred scanner capability.

`GET …/rules`, `…/rules/{kind}:{rule_id}` and its `/history` return reviewed
`wtr.rule-status.v1` projections of committed heartbeat, battery, transport,
motion and geofence state under current `read` authority. Each stored document is
restored through its pure constructor first; a damaged document returns
`storage_unavailable`. Observations, evidence bundles, samples and coordinates
are never included.

Administrators can save and delete `wtr.rule-definition.v1` heartbeat, battery,
motion, geofence and suspicious-movement definitions for one enrolled Thing through `Service.save_policy/6`,
`Service.delete_policy/6`, `POST …/policies` and `POST …/policy_deletions`.
The service assigns each revision from its commit generation, validates the
policy through the pure constructor and requires a battery rule to name a
declared numeric Property in the same unit. Motion and geofence definitions bind
their complete ordering, uncertainty, dwell or geometry policy. A
suspicious-movement definition names a motion definition for the same Thing and
privately retains that exact motion policy together with closed arming and
owner-presence predicate choices. It is event-only and creates no synthetic
current rule status. Saving it evaluates any already committed exact inputs;
subsequent motion materialisation, arming and owner-presence mutations reevaluate
the live binding in their own transaction. Position rules evaluate a
position only when the committed bundle contains exactly one, so the service
never chooses among sources without an admitted selection policy. A Thing has at most eight definitions,
listed for readers through `Service.thing_policies/5` and `GET …/things/{id}/policies`.
`Service.thing_rules/5` and `GET …/things/{id}/rules` return their committed
statuses at the same snapshot.
Saving a definition evaluates it against the Thing's committed evidence, and each
materialisation of that Thing evaluates its definitions in the same transaction.
A deleted definition keeps its status history but is no longer scheduled.

`Service.set_arming/6` and `POST …/arming` commit one conditional `armed` or
`disarmed` state for an enrolled Thing. The private record retains a complete
exact `asset.armed` policy fact backed by administrative-operation evidence;
the reviewed `arming` resource returns only the public state, commit-derived
revision, change time and pseudonymous actor. It does not claim device contact or
dispatch a physical Action. When an exact live suspicious definition, matching
motion state and owner-presence fact exist, the same transaction stages the
revalidated event intent and reviewed alert. Unenrollment removes
the current state while retaining its version history.

`Service.admit_owner_presence/6` and `POST …/owner_presence` conditionally admit
a complete `owner.present` `PolicyFact` for an enrolled Thing. The fact must
restore from exact or strong content-bound evidence associated with that Thing;
older and same-time conflicting observations are rejected. The private record
retains the complete observation, evidence and bundle. The reviewed
`owner_presence` resource returns only present, absent or unknown, receiver and
admission times, a commit revision and a pseudonymous admitting actor. Missing
state and radio silence never become absence. Admission reevaluates exact live
suspicious definitions against the staged fact, matching motion state and arming
fact; a true result commits its stable intent and alert atomically. It sends no
notification and dispatches no physical Action. Unenrollment removes
the current projection while retaining its versions.

`Service.register_notification_endpoint/6`, `Service.notification_endpoints/4`
and the matching `notification_endpoints` HTTP resource manage at most eight
APNs registrations for the current administrator principal. Tokens are accepted
as bounded printable routing material, encrypted with an instance-derived key
and authenticated against the exact scope, principal, endpoint ID, app ID and
sandbox/production environment before entering durable storage. Public reads,
receipts and activity events expose no token or internal record identifier.
Rotation preserves the endpoint's original binding and creation time;
unregistration writes a tombstone. Registration does not enqueue, send or claim
delivery of a notification.

When a live rule event creates its durable alert, the same SQLite transaction
stages one lossy store-and-forward item for each active endpoint. The item carries
only `wtr.notification-reference.v1` and the opaque alert ID; rule kind, location,
evidence and credentials are excluded. Replay alerts stage nothing. Queue
overflow records a dropped outcome without rolling back canonical rule state or
the alert, and a pre-commit failure rolls the rule, alert and staged reference
back together. Hosts may explicitly configure `NotificationDispatcher` with one
provider adapter. Its supervised bounded worker claims only those notification
references, resolves the exact endpoint revision, rechecks the registration's
retained authority immediately before every provider call and never passes more
than the private target plus opaque alert reference to the adapter. Provider
acceptance completes the durable item at the application layer; retryable or
malformed outcomes stay pending. Permanent rejection and missing, rotated or
revoked targets are distinct terminal outcomes. An invalid-token response removes
only the still-matching endpoint revision before settling the item. Provider
acceptance, OS delivery and user reading remain distinct. No provider or APNs
credential is selected implicitly.

`APNsAdapter.new/1` admits an explicit Apple team ID, key ID, unencrypted P-256
`.p8` contents and sorted closed bundle-topic list. The private key stays in the
opaque redacted adapter value; the package never reads a key path or ambient
application setting. The adapter creates a current ES256 provider JWT and sends a
generic alert plus the opaque event reference through one bounded, verified Mint
HTTP/2 TLS exchange to the endpoint selected by the registration's exact
sandbox/production value. Requests use explicit topic, alert push type, priority,
zero expiry and request ID headers. Responses map invalid device tokens,
rate-limiting, server failures, timeouts and permanent rejection into the
dispatcher outcomes above. A host wires it without transferring key custody to
the public service API:

```elixir
{:ok, apns} =
  Wotex.Tracker.Service.APNsAdapter.new(
    team_id: "TEAMID1234",
    key_id: "KEYID12345",
    private_key: provider_key_pem,
    topics: ["org.wotex.tracker"]
  )

# server_options contains the required listener, store and credential options
Wotex.Tracker.Service.HTTP.Server.start_link(
  server_options ++
    [notification_dispatcher: [adapter: {Wotex.Tracker.Service.APNsAdapter, apns}]]
)
```

Provider acceptance still does not prove device delivery or user interaction.
Physical APNs delivery, application entitlements and notification-tap routing
require separately provisioned Apple credentials and mobile acceptance evidence.

Each recorded rule event also becomes a newest-first `wtr.alert.v1` record with
the reviewed event. `Service.acknowledge_alert/6` and `POST
…/alert_acknowledgements` let an administrator acknowledge a live alert once;
replay alerts are informational. Acknowledgement changes no rule state and
dispatches nothing. An alert names the Thing whose service definition produced
it, and `Service.thing_alerts/6` and `GET …/things/{id}/alerts` page one
Thing's alerts newest first; host-managed rule alerts have no Thing.
`Service.thing_trips/6` and `GET …/things/{id}/trips` expose only retained
`trip.started`, `trip.stopped` and `trip.interrupted` alerts for that Thing. The
cursor independently binds the caller, Thing, committed snapshot and page size,
and unrelated alerts cannot consume a trip-history page. Optional `from_at` and
`to_at` effective-time bounds must be supplied together and form a half-open
window that is also bound into every continuation.

`Service.trip_summary/6` and `GET …/things/{id}/trips/{trip}` reauthorize a
read-only reconstruction of one completed trip. The operation restores the
exact motion state and policy committed with `trip.started`, then evaluates at
most 100 retained materialisations through the immutable stop or interruption.
It returns public centre/lower/upper metres plus the complete included/excluded
segment ledger. Active or unknown trips are not final; missing, ambiguous or
noncanonical retained cohorts fail explicitly, and no observation, evidence,
bundle or sample identity crosses the service boundary.

`Service.analytics/5` and `POST …/analytics/query` accept the closed
`wtr.query-spec.v1` document. The service rechecks `read` authority inside a
dedicated read-only SQLite transaction, pins the current scope generation and
extracts numeric measurement rows from committed state history. It scans at most
100,000 matching rows across one to eight explicit series and returns a
content-identified `wtr.query-result.v1` with disclosure counts and preserved
gaps. The operation is read-only, so it does not use mutation receipts or
`Idempotency-Key`.

`Service.analytics_page/5` and `POST …/analytics/pages` split the same admitted
window into bounded bucket pages. An encrypted seven-day cursor binds the exact
query, page size, next page, principal, scope, instance and first committed
generation. Continuations exclude later writes and recheck current `read`
authority without retaining a SQLite transaction between requests.

`Service.route_history/5` and `POST …/routes/pages` reconstruct one bounded page
of retained position materialisations under current `read` authority. The first
page pins the committed generation; its encrypted continuation binds the exact
Thing, time window, replay policy, page size, principal, scope and instance.
Every retained observation is reauthorized before its private evidence is
restored. Public pages contain pseudonymized point/rejection identities and
tagged scalars, never raw evidence, bundle, observation or sample identities.
Missing or ambiguous position materialisations are explicit exclusions that
split otherwise adjacent segments. Route continuity is page-local: clients must
not join the last segment of one page to the first segment of another.

Analytics execution is capped at eight concurrent queries, two per principal and
sixteen starts per principal in each one-second window. Caller loss, store
shutdown or the configured timeout cancels the dedicated SQLite connection and
retains no query reservation. These limits are independent of the serialized
writer, so a canceled scan cannot leave the writer mailbox blocked.

Administrators can persist an absolute `wtr.saved-query.v1` definition or a
rolling `wtr.saved-query.v2` definition with closed line/area/points/table
visualization options. A rolling definition stores a duration matching its
admitted absolute `QuerySpec` template. On execution the host resolves a fresh
from-inclusive/to-exclusive absolute window ending one millisecond after its
current time; the result records the resolved bounds and identity. An incident snapshot
`wtr.saved-query.v3` pins its absolute query to the commit generation and result
identity the client displayed: saving reruns the query there and conflicts on a
different result, and each execution reruns it at that generation and reports
`revision_mismatch` if retained data no longer reproduces it. Save, update
and delete are idempotent generation-checked transactions; ownership is stored
privately and projected as a scope pseudonym. Ordinary resource reads and
history expose reviewed definitions and deletion tombstones.
`GET …/saved_queries/{id}/execute` rechecks current `read` authority and runs the
resolved query through the same bounded engine. Possessing or sharing a
definition grants no data access and does not call a model. Named display
timezones, prompting and graph rendering remain later contracts.

## Bounded operational history

`OperationalTelemetry.contracts/0` documents the closed
`[:wotex, :tracker, …]` request, query, import-stage, store, queue,
publication, resource, browser-render, browser-connection and native-resource
event names.
Measurements include integer microsecond
durations, query row counts, queue depth/bytes and processed/drop counts. Labels
contain only closed stage, operation, outcome, aggregation and resource
categories; they never contain scope, principal, record ID, position, prompt or
payload values. The service depends directly on `:telemetry`, but package
loading attaches no handler.

`OperationalHistory` is an explicitly started collector backed by owner-held
ETS. It retains at most 2,048 samples for 15 minutes by default (configurable up
to 10,000 samples and 24 hours), returns coherent snapshots with an epoch and
clears everything on restart. Invalid external events are ignored. Collector
loss cannot change durable tracking or alarm decisions. The explicit HTTP
`Server` supervises one collector by default and exposes it to host code through
`Server.operational_history/2`; no metrics server or exporter is required.
`OperationalHistory.window_page/2` pins an event filter, one-to-fifteen-minute
UTC window, epoch and sequence high-water mark. Each response combines a
bounded exact page with up to 1,000 graph samples and reports the number of
earlier matching samples left only in the exact pages. Continuations reject
changed filters/windows, collector restart and expiry rather than silently
changing the graph snapshot.
Hosts that need remote delivery can explicitly supervise `OperationalExporter`
with a collector and an `OperationalExportAdapter`. It exports ascending batches
of at most 1,000 sanitized samples, retains only one batch, times out adapter
work and retries without advancing its acknowledgement checkpoint. Batch
continuity distinguishes an initial retained snapshot, normal progress, an
exactly counted retention gap and collector restart with unknowable loss. The
host adapter owns endpoint credentials, transport and idempotency; its context
is redacted from exporter inspection. The default server starts no exporter.
The optional browser host contributes sanitized root LiveView `render.stop`
durations and marked `connection.stop` reconnect attempts to this collector.
Its browser adapter marks a connection only after the same LiveSocket has
opened once; a reload starts another initial connection. The host accepts only
its own endpoint event and retains duration plus closed surface, kind and
outcome labels. Socket parameters and page data are discarded. Native
host-resource coverage remains with the adapters that own those operations. The
Nerves and standalone Linux service hosts use the closed `native.sample` event
for fixed procfs system available memory, BEAM-process RSS and one-minute load.
The service validates the complete nonnegative integer measurement set and
retains only `nerves` or `service` surface and `linux_procfs` source labels.

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

OpenAPI **3.1.0**, contract revision **1.36.0**, is packaged at
`priv/openapi/v1.json` and served at `/api/v1/openapi.json`. Liveness is
`/health/live`; authenticated resources are under `/api/v1/scopes/{scope}`.
Use `Authorization: Bearer …`, and a UUIDv4 `Idempotency-Key` for POST mutations.
The read-only analytics and route-page POST operations use authorization without
an idempotency key.
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

The client uses Mint 1.10.1 with a five-second maximum deadline, one socket per
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
