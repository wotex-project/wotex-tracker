# Position evidence and explicit freshness

This is the first pure WTR.05 slice. `Wotex.Tracker.Position` admits normalized
position claims from a closed `EvidenceBundle`; `PositionFreshness` evaluates
explicit time and quality. It starts no process, reads no clock, performs no unit
conversion and makes no physical-device or canonical-selection claim. Motion,
trips, fences, multi-source selection and persistent rules are subsequent work.

## Position claim v1

Create an ordinary `Evidence` with `kind: :position`, explicit profile/decoder
revisions, source observations and optional operator association. Its `claim` is
a closed native JSON object with every field below, including explicit nulls.
Then call `Position.new(evidence_id, bundle)`. The constructor validates the
entire bundle and binds the returned view to its content identity. Modification
of the claim, raw capture, profile or interpretation invalidates that view.

| Field | Contract |
| --- | --- |
| `schema` | Exactly `wtr.position.v1` |
| `latitude`, `longitude` | WGS84 degrees, respectively −90…90 and −180…180 inclusive; both null when unavailable; `(0, 0)` is valid |
| `altitude_m` | Metres, null or −100,000,000…100,000,000 |
| `speed_m_s` | Metres per second, null or 0…100,000 |
| `horizontal_accuracy_m` | Null or 0…40,100,000 metres |
| `accuracy_kind` | `unknown` exactly when accuracy is null; otherwise `estimate` or `bound` |
| `source` | `gnss`, `cellular`, `wifi`, `ble`, `lorawan`, or `operator` |
| `fix_at`, `device_at` | Distinct Unix-millisecond integers or null; original fix time and device message time |
| `received_at` | Unix-millisecond integer equal to the named receiver observation's `observed_at` |
| `fix_clock`, `device_clock` | `trusted`, `untrusted`, or `unknown`; missing time requires `unknown` |
| `availability`, `quality` | Available coordinate: `available` with `valid`/`suspect`; absent coordinate: `unavailable` with `unavailable` |
| `receiver_observation_id` | Must be one of the claim's retained source observations |
| `source_units` | Closed object described below |
| `conversion_revision` | Nonempty bounded ID identifying the profile's source-to-normalized conversion |
| `raw` | Bounded JSON object preserving source values and source-specific uncertainty details |

The metric ceilings are admission budgets, not plausible-motion thresholds or
measured device limits. An uncertainty estimate is not promoted to a guaranteed
bound. A profile must qualify the meaning of its accuracy and clock declarations;
the constructor validates those declarations, not their physical truth. Position
availability applies to the coordinate: independently reported speed, altitude and
raw uncertainty remain preserved even if the coordinate is unavailable.

`source_units` contains exactly `latitude`, `longitude`, `altitude`, `speed`,
`accuracy`, `fix_time`, `device_time`, and `receiver_time`. A supplied value
requires a nonempty source-unit ID. A missing value permits null or a retained
source-unit ID. For example, normalized speed is m/s even when the source unit
is `km/h`; the decoder owns the conversion and identifies its revision. The
profile's raw representation, time precision and timezone interpretation remain
provenance. No generic conversion engine or clock correction is implied.

`Position.to_map(position, bundle)` exports a `wtr.position-evidence.v1` object
containing the complete claim, source and parent evidence IDs, profile/decoder
revisions, declared confidence/reasons, association and bundle identity. This is a **private evidence export**, not a reviewed public
service projection. Distinct reception observations retain distinct identities.
Integers, floats, wide/negative Unix times, zero and null retain their native types.
No monotonic deadline is accepted as a named clock domain.

## Freshness policy v1

Admit all policy fields explicitly:

```elixir
{:ok, policy} = Wotex.Tracker.PositionFreshness.new(%{
  revision: "position-clock-v1",
  max_age_ms: 60_000,
  future_skew_ms: 2_000,
  missing_fix: :unknown,
  accept_suspect: false
})

{:ok, decision} = Wotex.Tracker.PositionFreshness.evaluate(
  position, bundle, policy, now_unix_ms
)
```

`max_age_ms` and `future_skew_ms` are integers in 0…604,800,000 inclusive. The
policy identity hashes every field plus algorithm `qualified-fix-first-v1`.
Changing content under an unchanged revision still changes the identity; forged
or stale policy structs fail. Callers must persist the complete admitted policy
when using it in a later stateful rule.

The decision uses this order:

1. Unavailable coordinates are unknown. Suspect quality is unknown unless the
   policy explicitly accepts it.
2. Reception later than `now + future_skew_ms` is unknown, including a receiver
   clock that jumped backwards relative to retained evidence.
3. A supplied fix requires `fix_clock: trusted`. Untrusted/unknown supplied fix
   time returns unknown and **never falls back** to receiver/device time.
4. A trusted fix is the age basis. A fix after reception plus permitted skew is
   unknown. A fix later than now plus skew is future. Age greater than the maximum
   is stale; equality is fresh. Allowed small future skew retains its signed age.
5. Only a missing fix can use reception time, and only with explicit
   `missing_fix: :receiver_time`; otherwise it remains unknown. Device message
   time never replaces fix time. Delayed delivery cannot refresh an old fix.

Results have schema `wtr.position-freshness.v1`, status/reason, chosen clock and
timestamp, signed `age_ms`, explicit evaluation time, position evidence/bundle
identity and policy revision/identity. Unknown decisions retain the reason and
available decision provenance; they are not boolean false. No state transition,
reception deduplication, live alarm, physical Action or historical rewrite occurs.
