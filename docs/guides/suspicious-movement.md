# Three-valued suspicious movement

`Wotex.Tracker.PolicyFact` represents a true, false or unknown policy fact backed
by a retained evidence record and closed bundle. Its claim names the predicate,
derivation-policy revision and reason. Exact or strong evidence is required.
Missing evidence and radio silence do not automatically create a false fact.

`Wotex.Tracker.SuspiciousMovement` evaluates the rule:

```text
confirmed moving AND armed true AND owner-present false
```

The rule policy binds the complete motion policy, exact armed and owner-presence
predicate names, fact age/future-skew limits, and whether unknown owner presence
is explicitly treated as absence. That last choice defaults to false. Armed
unknown always remains unknown.

The evaluator uses three-valued conjunction: any false condition clears the rule,
all true conditions trigger it, and every other combination is unknown. This
means a disarmed asset or a present owner clears the rule even when another input
is unknown, while absent BLE evidence cannot trigger an alarm under the default
policy.

A true result emits a stable `suspicious_movement` event binding the active trip,
motion state, both evidence facts and rule identity. Re-evaluation is idempotent;
replay produces the same event identity and prohibits physical Action dispatch.

The service `RuleEvent` port retains closed motion-state, armed-fact,
owner-presence-fact and rule-policy documents. It restores and re-evaluates those
inputs before SQLite atomically records the stable intent and public event without
manufacturing another canonical state. An exact retry after restart returns the
original generation. A collision that attempts to change live/replay effect
metadata conflicts.

The service admits an owner-presence input only as a complete, content-validated
`owner.present` `PolicyFact` backed by exact or strong evidence associated with
the enrolled Thing. Admission is conditional and strictly advances receiver
observation time; an older or same-time conflicting fact cannot replace current
state. The reviewed public projection contains only present, absent or unknown,
the observation/admission times, a commit revision and a scope pseudonym. The
closed observation, evidence, bundle and fact identities remain private. Missing
state and radio silence still do not become an absent fact.

An administrator can persist a `suspicious_movement` rule definition for an
enrolled Thing. Its exact parameters are `motion_rule_id`,
`maximum_fact_age_ms`, `future_skew_ms` and `owner_unknown_as_absent`. The
referenced ID must be a motion definition for that same Thing and cannot be the
suspicious definition itself. At admission, the service restores and privately
embeds that exact motion policy; the public definition exposes only its content
identity and the reviewed parameters, never the nested policy or predicate
names. The definition is event-only, so saving it does not manufacture a current
rule-status row.

The service reevaluates every live exact binding when that definition is saved,
when its Thing is materialised with a motion transition, and when the Thing's
arming or owner-presence fact changes. A staged input wins over the preceding
snapshot, so a true result's private intent, reviewed public event and alert share
the triggering mutation's generation and rollback boundary. Missing inputs,
stale facts, a false or unknown conjunction and a changed/deleted referenced
motion definition emit nothing. Replaying the triggering operation is idempotent;
no notification or physical Action is dispatched.
