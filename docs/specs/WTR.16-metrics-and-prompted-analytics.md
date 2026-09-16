# WTR.16 Metrics, prompted analytics and dynamic graphs

## Status

Accepted target contract. A first pure deterministic query core implements
content-identified absolute-UTC numeric rows, closed query/result codecs and
bounded count/min/max/mean/last aggregation. The first service adapter adds
authorized committed SQLite snapshots, a versioned HTTP operation, bounded
global/per-principal execution and cancellation. The transactional service also
persists, versions, executes and tombstones owned absolute and rolling query
definitions with closed visualization options. Each rolling execution records
fresh resolved absolute bounds. Closed telemetry now covers requests,
queries, import admission/decoding, transactional commits, forward-queue depth
and overflow, publication reconciliation and store checks through an explicitly
supervised bounded volatile collector. The explicit HTTP host also samples
global BEAM memory, process and port counts into that collector. Reconnect,
rendering and OS-native resource events remain with their owning adapters.
Host-only operational pages pin a collector epoch and sequence high-water mark;
continuations reject restart, altered filters and expired samples.
Encrypted analytics continuations now bind the exact query and first committed
generation while reauthorizing every bucket page. Dashboard composition and
sharing, prompt integration and graphs remain required product deliverables.
The shared browser now submits a bounded structured numeric query for one asset
and renders snapshot-bound line, area and point graphs with separate paths at
gaps, time-window controls and an exact table with exclusion counts. Scheduled
live refresh, browser save/edit controls and cross-surface graph acceptance
remain. Readers can list and rerun existing saved definitions through the same
service facade; their ownership and query authority stay with the service.
Model execution is explicitly configured and can be disabled; deterministic
tracking and structured analytics MUST remain useful without AI or any external
observability service.

## Data and instrumentation

Separate operational measurements from asset history:

- operational telemetry measures ingestion, decoding, admission, queue depth,
  dropped records, commit/publication outcomes, reconnects, query/render work and
  native resource health;
- tracking history contains authorized positions, motion, battery, events and
  source-quality evidence under the durable WTR.06 store contract.

Use `:telemetry` events with documented names, measurement types/units and a
closed metadata vocabulary. A host owns handler installation, polling and
collector supervision. Loading the library installs nothing. Operational metrics
are not a durable history store and loss of a collector cannot lose an admitted
observation or change an alarm decision.

Default host operation MUST include bounded local operational history and
dynamic views without a metrics server. ETS may hold explicitly owned volatile
samples with documented expiry and restart semantics; durable asset history,
saved queries and dashboard definitions belong to the transactional store.
Labels never include raw identifiers, positions, arbitrary user/profile strings,
prompts or payloads. Tenant/device drill-down uses authorized queries rather than
unbounded metric label cardinality.

An optional PromEx plugin contributes to the host's configured collector; it must
not replace a global storage adapter or start a competing collector. Prometheus,
GreptimeDB or another remote store may be configured through an explicit exporter/
query adapter. None is a mandatory service. Retention, export retry, destination
authorization and failure behavior are host policy. No metric handler performs
blocking network/model calls in the ingestion caller.

## Query contract

Implement a versioned immutable `QuerySpec` and `QueryResult` contract exposed
through the same service API used by every frontend. `QuerySpec` contains an
authorized dataset/measurement selection, typed filters, time window, timezone,
grouping, allowed aggregation, ordering and result budget. It is a closed data
format, never SQL, Elixir, JavaScript, a module name or executable expression.

Authorization resolves the effective scope from the authenticated principal;
neither a prompt nor a client-supplied tenant ID can widen it. Pin dataset/schema,
rule/measurement and query revisions. Execute each query against a committed
snapshot, with resolved absolute time bounds, units, source/quality policy,
sample/row counts and any downsampling disclosed in the result. Snapshot expiry
is an explicit error; pagination must not quietly mix generations.

Operational-history queries bind a coherent retained snapshot and collector
epoch, and identify it as volatile. Collector restart/expiry cannot make a
cursor refer to different samples under the same identity. Do not promise an
atomic snapshot across an ETS collector and a separate durable/remote store;
cross-store joins require their own explicit consistency contract before use.

Missing, unknown, false, zero and numeric values remain distinct. Aggregations
declare missing-value handling and compatible units. Do not connect a line across
an unobserved interval, infer zero activity from missing reception, or combine
incompatible measurements. Timezone display does not change stored event time.
Empty authorized results differ from rejected queries and unavailable stores.

The initial closed query vocabulary MUST support filtering, time buckets,
count/min/max/mean and last-observed values over qualified numeric/time data,
with deterministic tie ordering and field-specific aggregation eligibility.
Last-observed uses qualified event ordering, not arbitrary storage enumeration.
Do not average identifiers, booleans or cumulative counters as sensor values.
Derived rates/trips use separately versioned deterministic measurement rules.

Default per-query budgets are 31 days, 8 series, 1,000 returned points per series,
100,000 scanned rows, 256 KiB encoded result and 5 seconds of execution. Hosts
can explicitly choose other finite validated limits for their deployment; these
are resource defaults, not maximum product history or measured capacity claims.
Longer histories use bounded pages/aggregations. Enforce limits during planning,
scanning and encoding, not after materializing unbounded input. Exceeding a
budget fails explicitly or uses a requested/disclosed aggregation; never silently
truncate a supposedly complete result. Test each configured boundary.

Bound concurrent queries and per-principal refresh rates before execution. Use
indexed time/identity lookup and incremental aggregates only when measured and
consistent with the snapshot contract. Cancel abandoned requests, release their
resources and discard late results from a previous query/session generation.

## Prompted queries

The application MUST provide a question-to-graph workflow over the same closed
query contract. The host configures one model/provider adapter with explicit
credentials, endpoint, disclosure policy, deadlines and budgets. A public
provider path independent of private Refpath is required for product acceptance;
a synthetic model peer alone proves only boundary behavior.

The model may propose a `QuerySpec` and explanatory text. The service validates
and authorizes the proposal, executes the deterministic query and renders the
returned data. It MUST NOT accept model-invented data points, arbitrary queries,
rendering code, URLs, tool chains or physical Actions. Clarify an ambiguous
question rather than silently broadening its scope. Show interpreted filters,
units and time window so the user can correct and rerun the query.

Send only the permitted schema/context needed for translation. Location history
and raw evidence are not automatically attached to a prompt. Host-owned limits
cover prompt/response bytes, model time, cost, retries and concurrent requests;
no unbounded autonomous loop is required. Treat model output and stored/device
text as untrusted input. Cancellation, provider failure and malformed output
leave tracking, existing graphs and saved structured queries usable.

BeamLens is an optional investigation integration over narrowly scoped service
tools. Runtime introspection is privileged operator functionality and MUST NOT
become the end-user analytics authorization boundary. A translator such as
ReqLLM belongs in a separately enabled host adapter. Refpath is a separate
optional connector under WTR.11 and remains absent/disabled by default. No
specific agent framework is required by the query engine or shared UI.

## Dynamic views and saved dashboards

Shared LiveView components MUST provide live updating line, area and point
views, pan/zoom, time-range/filter selection, inspectable sample details and
accessible tabular alternatives. Maps and chart hooks may handle gestures and
rendering; Elixir owns query validation, units, authorization and calculations.
Fixed images and developer notebooks do not satisfy the application gate.

Refresh consumes a bounded service subscription or scheduled query. Coalesce
render work without losing committed history; expose stale/disconnected/overflow
states. Historical inspection pauses follow-live explicitly. A changed filter
or account cancels previous work, and an old result cannot replace a new view.
Charts must expose source gaps, quality and aggregation rather than imply raw
resolution or live connectivity that the result does not contain.

Saved dashboards persist the admitted query, visualization options and ownership,
not just a bitmap or narrative. A rolling `last_24_hours` window resolves anew
on each execution, recording the actual absolute bounds. An incident snapshot
pins absolute bounds, snapshot/result identity and interpretation revisions;
retention expiry is disclosed if its evidence can no longer be reconstructed.
The model need not be called again to refresh a saved admitted query.

Concurrent edits use generation checks. Copying/sharing a dashboard does not
grant access to its underlying dataset. Revocation applies to existing streams,
cached projections and saved definitions; source deletion invalidates retained
results under the configured privacy policy. Export uses the same authorized
data contract and preserves units, time bounds, omissions and provenance.

An offline cache cannot receive instantaneous remote revocation. WTR.08/15
require local expiry and purge on sign-out/account switch, then re-authorization
and invalidation on reconnect; no cached grant authorizes a new server query.

## Hard acceptance gates

Test known-answer queries independently of model output: zero/missing/mixed
availability, integer/float fidelity, unit mismatch, daylight-saving boundaries,
late records, counter/reset behavior, stable ties and concurrent writes. Check
exact snapshot membership across pages and no false continuity across gaps.

Test prompts that request unauthorized assets, inject executable instructions,
invent fields, produce ambiguous/invalid JSON, exceed budgets or arrive after
cancellation. Synthetic provider tests are required; a separately recorded real
public-provider run must demonstrate a question producing a correct graph with
the configured disclosure policy. Provider absence must pass independently.

Exercise graph gestures, filtering, save/reload, rolling refresh and fixed
incident views on web, physical Pi display and iPhone under WTR.15. Kill/restart
the collector and store, exhaust retention, revoke access mid-query/stream and
race saved-query updates. Show that ingestion and deterministic alarms continue
with the collector, exporter, AI and UI absent or failed.

WTR.12 assigns browser/query acceptance to the analytics target and physical
surface evidence to the Pi/mobile/integrated targets. The same shared component
source is required; passing browser tests alone does not qualify a device.

Measure query/refresh latency, scanned rows, allocation and peak RSS for the
same inputs and host conditions before optimization. Record the selected
concurrency and update-rate budgets; do not replace correctness assertions with
flaky timing thresholds or treat a screenshot as dynamic-graph acceptance.
