# WTR.05 Tracking state, positioning and deterministic policy

## Status

Accepted target contract. No implementation claim.

## Tracking is evidence, not a GPS field

A tracked Thing may have multiple position observations with different sources, age, accuracy and trust. Tracker MUST preserve source evidence rather than collapsing all positions into an unqualified coordinate.

Position sources may include GNSS, cellular/network-derived location, Wi-Fi-derived location, BLE proximity to a known scanner, LoRaWAN gateway/site presence, operator enrollment, or another qualified source.

## Position evidence

A normalized position observation SHOULD include coordinate when available, source, source-specific accuracy/uncertainty, device timestamp when trustworthy, receiver timestamp, profile provenance, and freshness.

## Deterministic selection/fusion

A deployment may define a deterministic `best_position` policy based on source class, freshness, stated accuracy, impossible-speed rejection and explicit trust. More sophisticated numerical fusion may use `wotex_nx`, but the inputs, algorithm/version and output evidence MUST remain reproducible.

AI-generated location guesses MUST NOT become canonical position.

## State and events

Tracker MAY derive state such as stationary/moving, present/absent, owner-nearby, geofence membership, overdue heartbeat, suspicious movement and transport degradation. Every derived state MUST declare its input evidence and deterministic rule revision.

## Rules

Safety/security rules run without Refpath. Example policy:

```text
unexpected movement
AND owner-presence evidence absent
AND enrollment says asset is armed
=> suspicious_movement event
```

The rule engine MUST distinguish `false` from `unknown`. Missing BLE owner evidence, for example, is not automatically proof that the owner is absent unless the policy explicitly defines that interpretation.

## Time

Rules consume explicit timestamps and a caller-owned clock. Device clocks may be untrusted or drifted; receiver time and device time MUST remain distinguishable.

Pure evaluation receives a fixed `now` value, not a clock-reading side effect. Live host deadlines use local monotonic milliseconds under WTR.13. Device event time, receiver Unix time and monotonic deadlines are never compared as if they shared an epoch. Freshness, permitted future skew and the handling of missing device time are explicit rule inputs.

## Geofences

Geofence evaluation is deterministic geometry over qualified position evidence. A geofence transition MUST retain the position/evidence that caused it and MUST tolerate uncertainty according to explicit policy rather than pretending every coordinate is exact.

## Store and replay

Late/offline observations may update history without necessarily generating a present-time alarm. Replay policy MUST distinguish event time from ingestion time and prevent old records from re-triggering live theft/tamper actions unless explicitly configured.

Before implementing stateful policy, specify deterministic ordering/tie behavior, a bounded late-arrival window, sequence wrap/reset and reconnect scope, and the event idempotency key. Measurement deduplication must not discard distinct reception provenance or treat matching sequence numbers from different devices as one measurement. Apply deduplication, canonical state changes and resulting event intent in the same host transaction. Replay and live evaluation have explicit modes; historical reprocessing does not dispatch physical Actions. WTR.06 defines admission and publication outcomes.
