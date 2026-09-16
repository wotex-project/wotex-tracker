# Evidence-backed heartbeat state

`Wotex.Tracker.HeartbeatTransition` derives current or overdue heartbeat state
from an admitted receiver `Observation`, an immutable policy and caller-supplied
Unix milliseconds. It reads no clock and starts no timer. A host supplies `nil`
as the observation when evaluating a scheduled time tick.

The policy declares a maximum silence interval and permitted receiver-time future
skew. Threshold equality is current; the first integer millisecond after the
interval is overdue. Initial evaluation establishes a baseline even when the
observation is already overdue, rather than inventing a transition that was never
observed by the state machine.

State retains the complete last observation and its content identity, derived
deadline, current/overdue status and latest evaluation time. New observations use
a total receiver-time, observation-ID and content-identity order. Exact content is
a duplicate. Older content is historical. Reusing an observation ID with changed
content conflicts. Historical input can accompany a time tick but cannot replace
the canonical heartbeat.

A current-to-overdue change emits `heartbeat.overdue` at the exact derived
deadline. A newer current observation emits `heartbeat.recovered`. A policy
revision emits `heartbeat.recomputed`, even when it changes the derived status,
so it cannot masquerade as newly observed silence or recovery. Event identities
bind both observation and policy identities and exclude live/replay mode.

Caller-clock regression and observations beyond permitted future skew return
unknown without changing canonical state. Replay returns the same state and event
identity as live evaluation while prohibiting physical Action dispatch. A host
must schedule monotonic deadlines separately and persist state/event intent in its
own transaction.
