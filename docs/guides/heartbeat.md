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
must schedule monotonic deadlines separately from receiver Unix time.

The service package persists a changed heartbeat result through the same generic
rule transaction used for transport health. Closed policy/state JSON restores
through the pure constructors. `RuleTransition` re-evaluates the result and binds
its expected prior identity; `Store.commit_rule/2` writes canonical state,
immutable history and any stable event intent at one scope generation. Restart,
exact retry, stale-writer and replay-prohibition semantics are shared across the
supported rule kinds. An explicitly started host owns scheduler and dispatcher
supervision; recording a new live event atomically stages only the minimal
per-endpoint notification references, never physical delivery.

`Wotex.Tracker.Service.RuleScheduler` is the explicit host scheduler for this
deadline. It reads at most 1,024 persisted heartbeat and battery states, converts
the next absolute rule boundary once into a local monotonic deadline and replaces
that timer only when the durable state identity changes. On restart it rebuilds
the deadline from the current receiver clock; an elapsed deadline runs
immediately. Before evaluation it rereads the exact durable state, then uses the
pure live transition and `Store.commit_rule/2`. Stale timer tokens cannot update
a newer state. The default explicit HTTP host supervises one scheduler, while
package loading still starts nothing. An overdue intent retains
`separate_authorization_required`; the scheduler never performs provider delivery
or a physical Action.

An administrator can also bind a heartbeat definition to an enrolled Thing through
the service `policies` resource. The service evaluates it against the Thing's
latest materialised receiver observation when the definition is saved and
whenever the Thing is materialised again, in the same transaction. Deleting the
definition stops scheduling while keeping its status history.
