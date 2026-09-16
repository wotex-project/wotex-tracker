# Bounded movement evidence

`Wotex.Tracker.PositionMovement` is the pure two-fix movement classifier. It
consumes two complete `PositionSample` values, a content-bound movement policy
containing the complete `PositionOrder` policy, and caller-owned Unix `now`. It
does not retain state, establish a trip, read a clock or dispatch an Action.

The policy declares:

- moving and stationary speed thresholds in metres per second;
- moving and stationary distance thresholds in metres;
- a maximum physically plausible speed;
- a maximum event-time gap;
- `:require_bound` or `:coordinate_only` uncertainty treatment.

Stationary thresholds must be no larger than moving thresholds, which creates an
explicit hysteresis band. The moving threshold must not exceed the plausible
speed limit. Every field, nested ordering-policy identity and algorithm name is
part of the policy identity.

## Distance and uncertainty

Centreline distance uses algorithm `wgs84-authalic-bounded-segment-v1` and the
same authalic radius as circle geofences. Longitude is periodic across the
antimeridian. Altitude and a device-reported speed field do not replace the
distance between the two qualified coordinates.

With `uncertainty: :require_bound`, both endpoints need guaranteed horizontal
accuracy bounds. If their sum is `u` and centreline distance is `d`, the possible
distance is `max(d - u, 0)…d + u`. Missing accuracy or an estimate returns
`unknown`. `:coordinate_only` deliberately uses `d…d` and records that lower
assurance policy.

The event-time gap must be positive and no larger than the declared maximum.
Distance bounds divided by that gap produce lower/upper speed bounds. The result
is then classified in this order:

1. a lower speed above the plausible maximum is `implausible`;
2. lower speed **and** lower distance at or above both moving thresholds is
   `moving`;
3. upper speed **and** upper distance at or below both stationary thresholds is
   `stationary`;
4. anything between those proofs is `indeterminate`.

Threshold equality is included. A repeated event timestamp is unknown, even when
receiver time breaks the ordering tie. Unavailable or suspect endpoints, a long
gap, late ordering and sequence anomalies remain explicit. Every result binds both
sample/evidence identities, the ordering decision, all distance/speed bounds and
the policy identity.

## Dwell-based motion and trips

`Wotex.Tracker.MotionTransition` consumes the classifier through a second
content-bound policy that declares minimum movement and stop durations. Its state
keeps the canonical ordering head, last-received sample, usable segment baseline,
pending dwell evidence, confirmed motion and active trip distinct.

The endpoint of the first moving or stationary segment starts a candidate. A
later consecutive segment of the same class must confirm the declared dwell.
This deliberately requires at least two classified segments even when the first
segment spans longer than the minimum duration. A changed or indeterminate class
clears the pending dwell. Initial stationary dwell establishes a baseline without
inventing a stop event.

Confirmed movement emits `trip.started` and stores a content-identified active
trip. Confirmed stationary evidence emits `trip.stopped`. Event identities bind
the rule, trip, onset and confirmation samples and exclude live/replay mode.
Policy revisions and excluded gaps or impossible segments emit
`trip.interrupted` for an active trip and reset motion to unknown. A valid
endpoint after a long gap can become a new segment baseline; a rejected
implausible endpoint cannot.

Late samples can advance last-received status without rewinding the canonical
motion head. Replay produces the same state, trip and event identities as live
evaluation while marking physical Action dispatch prohibited. State transitions
remain pure and caller-owned.

The service package serializes nested ordering/movement policies and complete
position samples without atom creation. Durable motion state stores one copy of
each referenced sample in a closed identity-keyed registry. Its generic rule
transaction restores pending dwell and active-trip state across restart, compares
the expected prior identity, and commits changed state, immutable history and any
stable trip event intent at one generation. Exact retries deduplicate; replay
intents retain prohibited physical dispatch. Position ingestion, trip-summary
materialization and notification delivery remain caller-owned.

## Bounded trip distance

`Wotex.Tracker.TripDistance` reconstructs a distance summary from an identified
active trip and a bounded, canonically ordered sample list. The first sample must
be the trip's candidate-onset sample and the list must contain its confirmation
sample. Duplicate or unordered lists fail instead of being silently sorted.

Every adjacent pair is reclassified through the trip's complete movement policy.
Only `moving` segments contribute centre, lower and upper distance totals.
Stationary, indeterminate, unknown and implausible segments remain in the returned
segment ledger with their reason and evidence identities. The algorithm never
joins the endpoints around an excluded segment, so a time gap or rejected fix
cannot silently add route distance.

The summary and policy carry content identities and an explicit sample limit.
This is deterministic bounded reconstruction over supplied evidence. Long-lived
storage, final closed-trip records and atomic event persistence remain host work.
