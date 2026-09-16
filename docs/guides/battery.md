# Evidence-backed low-battery state

`Wotex.Tracker.MeasurementSample` binds one measurement evidence record to its
complete `EvidenceBundle` and a deterministic receiver observation. If evidence
names several source observations, the latest capture is selected by receiver
time, observation ID and full observation content identity. The sample retains
the native measurement value, unit, availability, quality and lineage.

`Wotex.Tracker.BatteryTransition` consumes that sample with a content-bound
policy declaring:

- the exact measurement kind and unit;
- distinct low and clear thresholds;
- maximum receiver age and permitted future skew; and
- whether suspect measurements are eligible.

The low threshold must be below the clear threshold. Equality is included at
each boundary. Values between them retain an existing normal or low state; an
initial value in the band is unknown. Unavailable, stale, excessive-future and
policy-rejected suspect values are also unknown. Missing battery percentage is
never inferred from voltage.

Initial evaluation establishes a baseline. A normal or unknown state becoming
low emits `battery.low`; a low state meeting the clear threshold emits
`battery.recovered`. Aging a retained low sample past its freshness limit changes
the derived state to unknown without inventing a recovery event. Older samples
are historical, exact content is duplicate, and a reused evidence ID with changed
content conflicts.

Rule revision emits `battery.recomputed`. Event keys bind both policy and sample
identities while excluding live/replay mode. Replay produces the same state and
events as live evaluation and prohibits physical Action dispatch.

The service package persists changed battery results through its generic rule
transaction. Evidence, complete bundles and measurement samples use closed
native-JSON forms that restore through their constructors without creating
atoms. Policy/state restoration rechecks measurement scope, hysteresis status
and content identities. `Store.commit_rule/2` writes canonical state, immutable
history and any stable event intent at one scope generation, with restart,
optimistic-writer, exact-retry and replay-prohibition semantics. Measurement
ingestion, age scheduling and notification delivery remain caller-owned.
