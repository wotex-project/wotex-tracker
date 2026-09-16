# Deterministic measurement analytics

`Wotex.Tracker.QuerySpec` is a closed, immutable query over qualified numeric
measurement history. The first revision supports one measurement and unit, one
to eight explicit series, `valid` and optionally `suspect` quality, an absolute
Unix-millisecond window, UTC-aligned buckets, ascending or descending order, and
`count`, `min`, `max`, `mean` or `last` aggregation.

The window is inclusive at `from_at` and exclusive at `to_at`. It is limited to
31 days and must fit the requested bucket size within `max_points`, up to 1,000
points per series. This revision admits only `Etc/UTC`; named display timezones,
rolling windows and daylight-saving presentation belong to later service and UI
contracts.

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
`POST …/analytics/query` endpoint in service contract 1.7.0.

The adapter admits at most 100,000 matching measurement rows across all series.
Its `scanned_rows` value counts those extracted rows, rather than SQLite pages or
query-planner work. Duplicate requested measurements in one state version,
malformed committed scalars and invented quality values fail closed. The endpoint
uses scope-level `read` authority, produces no mutation receipt and requires no
idempotency key.

The service admits at most eight simultaneous queries, two from one principal,
and sixteen starts per principal per second. Each accepted query uses its own
read-only SQLite connection. Caller loss, store shutdown or the configured
five-second deadline cancels the connection through its busy and progress
handlers and releases the reservation. Query pagination, rolling windows, named
display timezones, prompt translation and graph rendering remain required by the
analytics target contract.

The service emits closed `request.stop`, `query.stop`, `ingest.stop`,
`store.stop`, `queue.stop`, `publication.stop` and `resource.stop` telemetry.
Measurements cover microsecond durations, scanned rows, current pending queue
depth/bytes, processed items and overflow drops. Metadata is limited to bounded
stage, operation, outcome, aggregation and resource categories.

An explicitly started `OperationalHistory` collector retains volatile ETS
samples under a unique restart epoch. The default HTTP host supervises that
collector and host code reads it through `Server.operational_history/2`.
Package loading remains inert, and collector failure cannot affect a committed
observation or rule decision. Reconnect, rendering and native host-resource
events belong to the adapters and UIs that perform those operations and remain
required for the complete product instrumentation contract.

`Service.save_query/6` and `POST …/saved_queries` persist an admitted absolute
query with closed visualization options, private ownership and a public owner
pseudonym. Scope-generation checks serialize concurrent edits, operation IDs
make retries idempotent, and history retains every definition version plus an
explicit deletion tombstone. Only the owning administrator can update or delete
the record.

`GET …/saved_queries/{id}/execute` loads the exact structured query, validates it
again and passes it to the normal analytics executor. The caller still needs
current `read` authority; a copied definition is never an access grant. Execution
does not invoke a model. This first saved-definition revision pins absolute
incident bounds. Rolling windows, sharing policy and UI dashboard composition
remain future contracts.
