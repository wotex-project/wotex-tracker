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
ingestion and notification delivery remain caller-owned.

The explicitly started service `RuleScheduler` also reconstructs battery time
boundaries from durable state. A fresh normal/low sample is reconsidered at the
first stale millisecond; an excessive-future sample is reconsidered when it enters
the permitted future-skew window. These absolute receiver times are converted to
local monotonic deadlines without serializing a monotonic value. Aging low state
to unknown records no recovery event. A future sample that first becomes eligible
may record the same deterministic low transition as direct live evaluation, but
the resulting physical Action still requires separate authorization.

A service battery definition names a declared numeric Thing Property and exact
unit, such as RAWv2 `batteryVoltage` in `V`. The service builds the measurement
sample from the Thing's materialised evidence bundle whenever the definition is
saved or the Thing is materialised, and commits any changed state with that
mutation. It never converts voltage to a percentage.
