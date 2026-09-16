# Bounded geofence geometry

`Wotex.Tracker.Geofence` is the pure geometry part of WTR.05. It admits a
content-bound circle or simple polygon, validates one immutable `Position`, and
returns `inside`, `outside`, `uncertain`, or reasoned `unknown` membership. It
does not choose the canonical position, read a clock, remember prior membership,
infer a crossing, emit an event, or dispatch an Action.

## Fence value

A fence has nonempty `id` and `revision`, a `shape`, a `boundary` policy
(`:inside` or `:outside`), and an `uncertainty` policy (`:require_bound` or
`:coordinate_only`). Every field and the algorithm name are included in the
fence identity. A modified struct or precomputed geometry fails validation.

Circle input is:

```elixir
%{
  id: "home",
  revision: "yard-v1",
  shape: %{kind: :circle, latitude: 59.3293, longitude: 18.0686, radius_m: 50},
  boundary: :inside,
  uncertainty: :require_bound
}
```

Latitude/longitude are WGS 84 degrees and radius is 0…1,000,000 metres. Circle
distance uses algorithm `wgs84-authalic-haversine-v1` and authalic radius
6,371,007.180918475 m. That constant is derived from the official WGS 84
semi-major axis 6,378,137.0 m and inverse flattening 298.257223563. The algorithm
is a spherical equal-area approximation pinned for reproducibility; it is not an
ellipsoidal geodesic or a survey-grade boundary claim. Longitude differences are
periodic, so circles work across ±180°.

Polygon input uses 3…64 vertices:

```elixir
%{kind: :polygon, vertices: [
  %{latitude: 59.32, longitude: 18.05},
  %{latitude: 59.32, longitude: 18.08},
  %{latitude: 59.35, longitude: 18.08}
]}
```

Algorithm `wgs84-authalic-local-polygon-v1` unwraps consecutive longitudes by
the shortest unambiguous delta, takes the mean unwrapped coordinate as origin,
and projects to a local equirectangular plane using the same authalic radius.
Ray crossing and distance-to-segment operate in that one plane. This admits
antimeridian fences such as 179° to −179°. An exactly 180° edge is ambiguous and
rejected. Polygons are limited to 1,000 km projected width and height and mean
latitude within ±85°. Duplicate vertices, a repeated closing vertex, area below
1 m², self-intersection, invalid coordinates and shapes outside those limits are
rejected rather than silently simplified. Edges are straight in this pinned
projection, not great-circle or ellipsoidal geodesics.

## Boundary and uncertainty

Exact coordinate membership obeys `boundary`: a point on an edge or circle is
inside only for `:inside`. The geometry tolerance for a computed boundary is
1 μm in its metre representation; this numerical tolerance is not sensor
accuracy or a physical precision claim.

With `uncertainty: :require_bound`, missing accuracy returns `unknown` and an
`estimate` returns `unknown` because it is not a guaranteed bound. A declared
`bound` expands the possible position in all directions:

- if the complete bound remains on one side, membership is proven;
- if it reaches/crosses the boundary, membership is `uncertain`;
- equality follows the explicit boundary policy.

For a circle, the calculation uses centre distance ± accuracy. For a polygon,
it uses the minimum distance to a projected edge. With
`uncertainty: :coordinate_only`, the fence deliberately classifies the reported
coordinate and records the original accuracy/kind without using it. This mode is
an explicit lower-assurance policy, not an assertion that the coordinate is exact.

The `wtr.geofence-membership.v1` result binds fence ID/revision/identity and
position evidence/bundle identity. It includes policy values, accuracy, centre
or boundary distance, algorithm and a stable reason. Unavailable positions are
`unknown`; false, null and uncertainty never collapse into ordinary `outside`.

## Ordered state transitions

`GeofenceTransition` consumes a `PositionSample`, the complete `PositionOrder`
policy, an explicit `:live` or `:replay` mode and caller-owned Unix `now`. Its
content-bound policy names the rule and revision and fixes a maximum time gap for
ordinary entry/exit transitions. The first certain membership establishes a
baseline. A later inside/outside change emits `geofence.entered` or
`geofence.exited` only when the event-time gap is at or below that limit. A larger
gap establishes a fresh baseline instead of silently bridging missing history.

State keeps three facts separate:

- the latest sample accepted by event/sequence ordering;
- the latest admitted receiver capture and its ordering outcome;
- the latest certain geofence membership and its full position evidence.

An uncertain/unknown membership can therefore advance ordering and last-received
status while leaving last-valid membership unchanged. A historical sample can
advance last-received status without rewinding the ordering head. Exact duplicate,
sequence conflict and future-time decisions do not invent a transition.

Changing fence content or the rule policy recomputes against the supplied current
sample. If a prior certain baseline exists, this emits `geofence.recomputed` with
reason `fence_revised`, `rule_revised`, or `fence_and_rule_revised`; it never
masquerades as entry or exit. An edit without certain membership clears the old
baseline because membership under old geometry cannot be reused.

Event identity hashes rule/fence identities, kind/reason, both endpoint sample
identities/statuses and event time under algorithm
`geofence-transition-idempotency-v1`. Processing mode and evaluation time are
excluded, so the same ordered history yields the same event ID in live and replay.
Replay always returns `physical_action_dispatch: "prohibited"`; a live event says
that separate authorization is required. This pure module never dispatches an
Action or persists state.

`Geofence.to_map/2` and `GeofenceTransition.to_map/2` export closed policy
documents. Geofence state exports the complete fence and rule plus a sorted,
deduplicated registry of the position samples still referenced by ordering,
last-received and last-valid state. Restoration reconstructs those references
through the public evidence constructors and rejects added, missing, duplicated,
dangling or altered documents. The service `RuleTransition` port re-evaluates a
changed result, compares the prior state identity inside SQLite, and commits the
state, history and stable event intent at one generation. Restart restoration and
exact retry deduplication preserve replay's prohibited dispatch metadata.

## Sparse inferred crossings

`Geofence.trace/6` evaluates the straight centreline between two separately
validated endpoint positions. Both endpoint memberships must be certainly
`outside`; an inside endpoint belongs to observed entry/exit processing, while an
uncertain or unknown endpoint remains unknown. A boundary-only touch is not a
crossing.

Circle traces use `wgs84-authalic-azimuthal-circle-segment-v1`: each endpoint is
placed in an authalic azimuthal plane centred on the circle, then the closest
point on the straight projected segment is compared with the radius. Polygon
traces use `wgs84-authalic-local-polygon-segment-v1`, the fence's existing bounded
projection, and test each interval split by edge intersections for polygon
interior. Both algorithms are interpolation conventions, not reconstructed routes.

`GeofenceCrossing` adds a content-bound rule and the complete ordering policy.
It requires event order and enforces maximum event-time and endpoint-distance
gaps; equality is accepted. A successful `geofence.crossing_inferred` event binds
both sample/evidence identities, both event times, both measured gaps and the
geometry algorithm. `crossing_time` is deliberately `nil`: sparse endpoints only
establish an interval. Event identity excludes processing mode and evaluation
time, so live and replay agree; replay prohibits physical Action dispatch.

The service `RuleEvent` port retains complete closed inputs while preparing an
inferred crossing, restores them and re-evaluates the pure result before storage.
SQLite records a new stable intent and public event at one generation; an exact
retry after restart returns the original generation. Because crossing is a
stateless inference, this path persists no synthetic canonical state. A collision
that attempts to change live/replay effect metadata conflicts.
