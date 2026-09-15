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

This classifier is the evidence input for a later motion/trip state machine.
One moving segment is not yet a trip, one spike cannot satisfy dwell, and an
implausible segment cannot silently become canonical distance.
