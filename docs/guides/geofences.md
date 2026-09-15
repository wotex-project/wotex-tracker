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

This slice establishes membership only. Initial baseline versus entry/exit,
fence-edit recomputation, sparse inferred crossings, event identity and atomic
rule persistence are subsequent state-transition work.
