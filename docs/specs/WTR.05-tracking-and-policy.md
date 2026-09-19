# WTR.05 Tracking state, positioning and deterministic policy

## Status

Accepted target contract. The pure library implements normalized position
evidence, explicit freshness, deterministic multi-source selection, stable event
ordering and protocol-sequence handling; circle/polygon geofences and sparse
crossing evaluation; motion/trip transitions and bounded trip distance; and
heartbeat, battery, suspicious-movement and transport-degradation policy.
`RouteReplay` now projects a bounded position-sample page into exact points,
rejections and gap-separated segments without inferring missing travel. The
service persists the implemented rule-transition forms, exposes redacted status
and commits an authorized evidence-backed administrative arming fact for an
enrolled Thing without claiming device contact. It also reconstructs one immutable completed trip at a
maximum of 100 retained materialisations under current read authority,
preserving every excluded segment and all distance uncertainty while keeping
private input identities internal. Administrators can also retain an event-only
suspicious-movement definition that binds the exact referenced motion policy for
the same Thing without exposing that nested policy publicly. The trusted decoder seam admits bounded
profile-backed position claims into immutable evidence, and an explicitly
configured service exposes a closed redacted state projection. The service now
admits complete content-validated owner-presence facts, retains their evidence
privately and never interprets missing state as absence. Input-triggered
suspicious-movement orchestration, notification delivery and product hardware
acceptance remain unfinished.

## Tracking is evidence, not a GPS field

A tracked Thing may have multiple position observations with different sources, age, accuracy and trust. Tracker MUST preserve source evidence rather than collapsing all positions into an unqualified coordinate.

Position sources may include GNSS, cellular/network-derived location, Wi-Fi-derived location, BLE proximity to a known scanner, LoRaWAN gateway/site presence, operator enrollment, or another qualified source.

## Position evidence

A normalized position observation MUST include coordinate when available, source,
source-specific accuracy/uncertainty when supplied, distinct fix/device/receiver
times under WTR.01, profile provenance and availability/quality. Coordinates use
WGS84 latitude/longitude in degrees; normalized distance/altitude use metres and
speed uses metres per second. Retain source units and conversion revision. Reject
out-of-range coordinates; `(0, 0)` is valid and not a universal missing sentinel.
Missing accuracy is unknown, not zero. Derived freshness uses explicit time.

## Deterministic selection/fusion

A deployment may define a deterministic `best_position` policy based on source class, freshness, stated accuracy, impossible-speed rejection and explicit trust. More sophisticated numerical fusion may use `wotex_nx`, but the inputs, algorithm/version and output evidence MUST remain reproducible.

AI-generated location guesses MUST NOT become canonical position.

## State and events

The tracking service MUST implement stationary/moving, trips/stops, geofence
membership/transitions, overdue heartbeat, suspicious movement, low-battery and
transport-degradation rules for evidence-qualified profiles. Every derived state
declares its input evidence, prerequisites and deterministic rule revision.
Present/absent and owner-nearby are distinct from radio reception and require
their own explicit evidence policy. Unsupported inputs produce unknown or an
explicit unsupported rule, never invented state. WTR.15 requires a qualified
smart-bike lane that actually exercises the required product rules.

Motion/trip policy MUST declare speed/distance thresholds, minimum movement and
stop durations, jitter/uncertainty treatment, event-time ordering and gap handling.
Do not equate a single speed spike with a trip or require car ignition evidence
for a bicycle. State transitions are pure functions of prior state, admitted
evidence, versioned policy and explicit time. Events have stable scoped identities;
persist transition state and event intent atomically under WTR.06.

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

The service scheduler applies that clock separation to persisted heartbeat,
battery and transport-health state. It converts the next receiver-time boundary
into a local monotonic deadline, rechecks the durable state identity before firing
and rebuilds deadlines after restart. It records live event intent atomically and
performs no notification or physical Action.

## Geofences

Geofence evaluation is deterministic geometry over qualified position evidence. A geofence transition MUST retain the position/evidence that caused it and MUST tolerate uncertainty according to explicit policy rather than pretending every coordinate is exact.

Support bounded circle and polygon fences with validated coordinates, explicit
edge/boundary inclusion, uncertainty and antimeridian handling. Pin the geometry
algorithm and supported shape constraints before implementation; reject invalid
or unsupported shapes rather than silently simplifying them. Initial membership
establishes a baseline instead of inventing a previously observed transition.
Fence/rule edits recompute membership with a new revision and an explicit reason.

Observed entry/exit and an inferred crossing between sparse fixes are distinct
event kinds. Segment interpolation MUST identify both endpoint observations and
its maximum permitted time/distance gap; it is not proof of the actual route.
Route replay displays gaps and uncertainty. Trips and distances cannot silently
include rejected positions or bridge gaps excluded by the versioned policy.

## Store and replay

Late/offline observations may update history without necessarily generating a present-time alarm. Replay policy MUST distinguish event time from ingestion time and prevent old records from re-triggering live theft/tamper actions unless explicitly configured.

Before implementing stateful policy, specify deterministic ordering/tie behavior, a bounded late-arrival window, sequence wrap/reset and reconnect scope, and the event idempotency key. Measurement deduplication must not discard distinct reception provenance or treat matching sequence numbers from different devices as one measurement. Apply deduplication, canonical state changes and resulting event intent in the same host transaction. Replay and live evaluation have explicit modes; historical reprocessing does not dispatch physical Actions. WTR.06 defines admission and publication outcomes.

Acceptance MUST include movement fluctuations, threshold equality, first fix,
missing accuracy, valid zero coordinates, repeated timestamps, out-of-order fixes,
clock jumps, long gaps, fence edits, boundary/antimeridian cases and sequence
reset/wrap. Replay the same admitted history through independent reference
expectations and live ingestion; explain intentional historical/live differences.
Last-received status may advance while last-valid position remains unchanged.
