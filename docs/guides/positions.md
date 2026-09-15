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

## Deterministic best-position selection

`PositionSelection` accepts at most 64 `%{position: position, bundle: bundle}`
candidates, an admitted selection policy, the admitted freshness policy, and the
same explicit Unix `now`. It validates every complete bundle and re-evaluates
freshness itself. Callers cannot provide a freshness label. Duplicate pairs of
evidence ID and bundle identity fail instead of increasing a candidate count.

The selection policy declares a nonempty ordered subset of accepted freshness
classes (`:fresh`, optionally `:stale`), a nonempty source priority, whether
unlisted sources are rejected or ranked last, how missing accuracy ranks or is
rejected, and an optional maximum stated horizontal accuracy. Every field and
the fixed algorithm name are bound to its identity. This is deterministic source
selection, not statistical or numerical fusion.

Qualified candidates have one total rank, in this exact order:

1. accepted freshness order;
2. declared source priority;
3. valid before suspect quality;
4. smaller stated horizontal accuracy, with missing accuracy handled by policy;
5. later selected freshness timestamp, then later receiver time;
6. lexical evidence ID, then lexical bundle identity.

Source priority therefore applies only after freshness. A delayed old GNSS fix
cannot defeat a fresh lower-priority source. Accuracy `estimate` and `bound` stay
distinct in the position claim; selection compares their stated metres only and
does not promote an estimate to a guarantee. Unknown/unavailable freshness,
unlisted sources, missing accuracy and accuracy-limit failures appear as explicit
rejections. No qualified candidate produces a successful `unknown` result rather
than choosing stale or unsupported data. The result records both policy identities,
evaluation time, selected rank, qualified count and stable rejected identities.

## Event ordering and protocol sequences

`PositionSample` binds one admitted position/bundle to optional protocol-sequence
evidence. Sequence evidence is a `transport` claim in the same closed bundle, is
a parent of the position evidence, and names the same receiver observation:

```elixir
%{
  "schema" => "wtr.sequence.v1",
  "scope_id" => "device-or-stream-a",
  "session_id" => "connection-a",
  "value" => 65_535,
  "modulus" => 65_536,
  "receiver_observation_id" => "capture-a"
}
```

The profile/decoder owns the meaning of those fields. `scope_id` prevents equal
counters from different devices or streams being treated as duplicates.
`session_id` is the explicit reconnect scope: a change permits a counter reset.
Moduli are 3…4,294,967,296. The sample identity covers the complete bundle and
the optional sequence claim; equal counter values alone never establish sample
identity or deduplication.

`PositionOrder` fixes event-time selection, permitted future skew, a bounded
late-arrival window and whether sequence evidence is disabled, optional or
required. A supplied fix time is usable only with a trusted clock. The optional
receiver-time fallback applies only when fix time is missing; an untrusted
supplied fix never falls back.

The complete order key is event time, receiver time, position evidence ID,
bundle identity and sample identity. Repeated timestamps therefore have a stable
total order. An exact sample identity is a duplicate. A lower key within the
late window returns `recompute_history`; one beyond it returns `history_only`.
Neither silently rewinds a live head.

Within one scope/session/modulus, modular deltas below half the range advance;
wrap is explicit, an exact half-range delta is ambiguous, and a larger delta is
older. Equal counter values with different evidence conflict. A changed session
is an explicit reset and a changed scope is independent. The classifier records
these decisions but does not buffer, mutate state, emit an event or dispatch an
Action. Stateful rules must use this ordering decision and define their stable
event identity before committing transitions.
