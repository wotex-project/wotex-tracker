# Deterministic measurement analytics

`Wotex.Tracker.QuerySpec` is a closed, immutable query over qualified numeric
measurement history. The first revision supports one measurement and unit, one
to eight explicit series, `valid` and optionally `suspect` quality, an absolute
Unix-millisecond window, UTC-aligned buckets, ascending or descending order, and
`count`, `min`, `max`, `mean` or `last` aggregation.

The window is inclusive at `from_at` and exclusive at `to_at`. It is limited to
31 days and must fit the requested bucket size within `max_points`, up to 1,000
points per series. The pure query contract always carries resolved absolute
bounds. This revision admits only `Etc/UTC`; named display timezones and
daylight-saving presentation belong to later service and UI contracts.

`Wotex.Tracker.QueryRow` carries the normalized input to the pure evaluator. An
available row has a finite numeric value. An unavailable row has `nil`. The
measurement, series, event time, unit, quality and retained evidence identity all
participate in its content identity. Storage adapters must derive rows from their
committed history rather than accept client-authored evidence identities as
authorization.

`Wotex.Tracker.Analytics.evaluate/4` takes explicit rows, an admitted query and a
committed snapshot identity. It starts no process and reads no clock or store.
The caller remains responsible for authorization, indexed snapshot selection,
the five-second execution budget and cancellation. The evaluator rejects
duplicate row identities and unit conflicts, scans at most 100,000 supplied
rows, and produces the same result for every permutation of the same rows.

Unavailable rows and rows outside the admitted quality set are excluded and
counted separately. Empty buckets are omitted, so consumers must render a gap
rather than a zero or a connecting line. `last` orders by event time and then by
row identity, independent of storage enumeration. Every point discloses its
sample count, last event time and last row identity.

`Wotex.Tracker.QueryResult` binds the exact query document, snapshot, ordered
series, disclosure counts, bucket geometry and points to one content identity.
Its closed native-JSON codec enforces the 256 KiB materialization budget and
rejects extra fields, changed identities, inconsistent counts, duplicate buckets
and malformed aggregation values.

`Wotex.Tracker.Service.analytics/5` is the first durable adapter. It accepts only
the closed serialized query, authenticates the caller, rechecks `read` authority
inside a SQLite read transaction and pins the current scope generation. For each
explicit series it extracts matching measurements from committed state history,
then passes admitted rows and a scope-generation snapshot identity to the pure
evaluator. The same operation is available as the read-only
`POST …/analytics/query` endpoint in the current service contract.

The optional shared browser exposes the first structured query at an asset's
**Explore measurement history** link. It uses the current retained numeric
measurement and unit as its initial selection and defaults to the 24 hours
ending just after that state's observation time. The operator can change the
absolute UTC bounds, bucket width and aggregation. The resulting table shows
only qualified buckets, with the committed snapshot and excluded-row counts;
it does not infer values between buckets or claim live connectivity. The
browser route requires the same `read` grant as the service query. Line, area and
point views project the returned points to SVG without introducing new values;
each run of adjacent observed buckets has its own path. The table gives exact
values and event times, and buttons shift or zoom the absolute UTC window.
When a host explicitly installs a prompt adapter, the same page also accepts a
bounded natural-language question. The adapter receives only that question,
the currently permitted measurement names and units, the closed query choices
and current UTC time. It receives no asset identifier, reading, service bearer
or evidence. It may return a clarification or a proposed set of form fields;
extra fields, invented measurements and invalid choices are rejected. A proposal
still goes through the ordinary `QuerySpec` constructor and authorized service
query. The displayed explanation and selected fields let the reader inspect the
interpretation. Without an adapter, the structured query remains available.
The quality selector admits valid readings, suspect readings, or both. Invalid
readings remain excluded. The selected quality set is part of the closed query
identity and persists with a saved dashboard; an unrecognized selection is
rejected before the service request.
After a successful unsaved query, **Start follow mode** captures the committed
scope event cursor before refreshing the result. Every five seconds it checks
for later commits. A changed scope causes one authorized state read and query;
the query duration stays fixed while its absolute UTC window moves to end just
after the asset's newest retained observation. A commit racing the query remains
visible to the next cursor check. Temporary service failure keeps the previous
result marked **stale** and retries from a fresh snapshot. Lost read authority or
a missing asset clears the result and stops following. Running or prompting a
new query, shifting or zooming the historical window, refreshing the asset,
preparing a save or pressing **Stop follow mode** cancels the timer. A quiet
scope does not rerun the query.
The Dashboards navigation lists retained saved definitions in bounded pages.
Opening one shows its stored query and window policy; running it invokes
`Service.execute_saved_query/5` after current authorization. A rolling
definition resolves a new window on every run. One-series definitions use the
shared graph/table component. Multi-series definitions can show line, area or
point traces on one common scale, with separate paths for each observed run;
each series also keeps an exact table, including empty-series disclosure.
After running a saved definition, any reader can switch that displayed result
between table, line, area and points. The switch uses the result already on the
page, preserves its snapshot and identity, and does not edit the saved view.
A reader can shift or zoom the displayed result's resolved absolute UTC window.
Each adjustment runs a new authorized structured query and is labelled as an
exploration of the saved result. It stops automatic refresh; **Run saved query**
returns to the stored fixed or rolling window. An invalid window or temporary
query failure keeps the last successful result, while loss of read authority
clears it. Navigation never edits the saved definition.
An administrator can choose **Prepare save** after running a one-asset query,
then name a fixed incident or rolling dashboard. The page address gains a
stable operation reference before the save form appears. Submission captures
the scope generation, persists the admitted query and visualization, and checks
the resulting receipt against the saved definition and asset. A lost response
leaves an explicit unknown outcome; revisiting the address or checking the
operation resolves the durable receipt without sending a second save.
On a saved dashboard, an administrator can prepare an edit to its title and
view or prepare a deletion. Each action captures the current scope generation
and puts its own operation reference in the page address. An uncertain response
hides the action until the retained receipt reports whether the edit or deletion
committed. The service still enforces ownership and current authorization.
Any reader can start automatic refresh on an open saved dashboard. The page
rechecks the definition and reruns its query every 30 seconds while it stays
open. A temporary failure keeps the last successful result marked **stale** and
retries; deletion or lost read authority clears that result and stops refresh.
An edited saved view appears on the next successful refresh unless the reader
has chosen a temporary view for this page; that choice stays in place while
refresh continues.
Manual runs, definition refreshes and navigation stop the timer.
After a query runs, **Export result JSON** rechecks current read authority and
reruns the same closed query before downloading the result shown on the page.
The download proceeds only if the result identity is unchanged; a saved
dashboard also requires its stored definition to remain accessible and unchanged.
The file includes the result
identity shown beside the snapshot, admitted query and resolved time bounds,
units, qualified buckets, exclusion counts and gap policy. If automatic refresh
is marked stale, export succeeds only if the last successful result still matches
the current authorized query. A new run creates a new exportable result.
An administrator can use **Compare saved queries** from the Dashboards page to
select two to eight definitions on one bounded list page. The browser accepts
only distinct series with identical measurement, unit, query settings and
window policy, then saves one new multi-series definition as an exact-table
dashboard. The current scope generation protects the save against concurrent
edits. Its operation reference remains in the page address, so an uncertain
reply can be checked without sending another save. Readers can run the saved
comparison under their current authority, but cannot create it. This is one
compatible query over several series; it does not combine unrelated windows or
grant access to the underlying assets.

`Service.analytics_page/5` and `POST …/analytics/pages` partition the admitted
bucket window into pages of 1 to 1,000 buckets. The first request supplies the
exact query, a page size and a null cursor. The response identifies its committed
scope generation and returns an encrypted continuation when more buckets remain.
Every continuation repeats the exact query and page size; the cursor binds both,
the next page index, principal, scope, instance and original generation. Later
commits are excluded, while current `read` authority is checked again for every
page. Ascending and descending requests traverse disjoint bucket windows in their
global order without retaining a long-lived SQLite transaction.

The adapter admits at most 100,000 matching measurement rows across all series.
Its `scanned_rows` value counts those extracted rows, rather than SQLite pages or
query-planner work. Duplicate requested measurements in one state version,
malformed committed scalars and invented quality values fail closed. The endpoint
uses scope-level `read` authority, produces no mutation receipt and requires no
idempotency key.

`Service.save_query/6` and `POST …/saved_queries` persist admitted queries with
closed visualization options, private ownership and a public owner pseudonym.
Scope-generation checks serialize concurrent edits, operation IDs make retries
idempotent, and history retains every definition version plus an explicit
deletion tombstone. Only the owning administrator can update or delete a record.
A request without `window` retains an absolute `wtr.saved-query.v1`. A request
with exact `{"kind":"rolling","duration_ms":…}` metadata persists a
`wtr.saved-query.v2`; its duration must equal the admitted template query range.

`GET …/saved_queries/{id}/execute` validates the definition and passes it to the
normal analytics executor without invoking a model. Each rolling execution
resolves a fresh absolute interval ending at `host_now + 1`, so an observation
at the current millisecond is included. The returned result records the resolved
bounds and content identity. Reading or sharing a definition never grants
access, and each execution reauthorizes the resolved query against its own
committed snapshot.

The service admits at most eight simultaneous queries, two from one principal,
and sixteen starts per principal per second. Each accepted query uses its own
read-only SQLite connection. Caller loss, store shutdown or the configured
five-second deadline cancels the connection through its busy and progress
handlers and releases the reservation. Named display timezones, prompt
provider interoperability and physical cross-surface graph acceptance remain
required by the analytics target contract.

The service emits closed `request.stop`, `query.stop`, `ingest.stop`,
`store.stop`, `queue.stop`, `publication.stop` and `resource.stop` telemetry.
Measurements cover microsecond durations, scanned rows, current pending queue
depth/bytes, processed items and overflow drops. Metadata is limited to bounded
stage, operation, outcome, aggregation and resource categories.

An explicitly started `OperationalHistory` collector retains volatile ETS
samples under a unique restart epoch. The default HTTP host supervises that
collector and host code reads it through `Server.operational_history/2`.
Package loading remains inert, and collector failure cannot affect a committed
observation or rule decision. An explicitly enabled browser host records
sanitized root LiveView render durations and marked reconnect attempts in the
same collector. The Nerves and standalone Linux service hosts also emit the
closed `native.sample` event from fixed procfs fields. It contains only system
available-memory bytes, BEAM-process RSS bytes and one-minute load multiplied by
1,000, labelled with the closed `nerves` or `service` surface and
`linux_procfs` source. Missing or malformed source files emit no partial sample.
Other operating-system adapters and physical resource acceptance remain required
for the complete product contract.
