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

This pure slice does not query SQLite, authorize a principal, page history, save
dashboards, translate prompts, emit telemetry or render graphs. Those host and
product integrations remain required by the analytics target contract.
