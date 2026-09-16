# Evidence-backed transport policy

`Wotex.Tracker.TransportCandidate` describes one qualified route. Its `bearer`
and `application_protocol` are separate fields: for example, `lte-m` may carry a
vendor framing protocol, while an IP bearer may carry HTTP or MQTT. Candidate
identity also binds cost and power classes, supported acknowledgement layers,
and two `PolicyFact` values:

- `transport.<candidate-id>.capable`, backed by capability evidence; and
- `transport.<candidate-id>.available`, backed by connectivity evidence.

Both facts must come from exact or strong evidence. A candidate does not open a
socket, send a frame or assert that a declared bearer is nationally available.

`Wotex.Tracker.TransportPolicy` declares separate ordinary and critical route
orders. It also fixes the accepted fact-policy revision, evidence freshness,
cost and power ceilings, required acknowledgement layer, and no-route outcome
for each severity. The request supplies the current cost and power budgets;
both the request and policy ceiling apply. This lets a deployment allow a more
expensive cellular route for a critical alarm without making that ordering a
global architectural rule.

Selection returns a complete route ledger. False, unknown, stale, excessive-
future or wrong-revision facts are rejected with distinct reasons. Missing and
unlisted candidates remain visible. The first eligible ID in policy order wins,
so input enumeration order cannot change the result. No ordinary route can
produce the declared `store_and_retry` outcome, while another policy may declare
`unavailable`.

Acknowledgement input names a delivery ID, candidate ID, exact layer and state.
The layers are `radio`, `network`, `transport`, `application` and
`durable_admission`; they are labels rather than an implied strength ordering.
An acknowledgement at a different layer cannot satisfy the policy. Pending or
unknown outcomes hold the decision and never trigger automatic retry. A definite
failure may select the next eligible route. This decision does not prove remote
application effect, device identity or authorization for a physical Action.

The pure library owns only this deterministic decision. A host owns bounded
queue admission, bytes/count/age limits, durable commit, retries and publication.
Tracker's service package already provides its SQLite transaction and commit-
outcome foundation, but it does not yet persist these policy decisions. Continuum
delivery and degradation values may carry later snapshots; they do not replace
Tracker's domain policy or provide a transport engine.

## Transport health

`Wotex.Tracker.TransportDegradation` turns validated decisions into a pure
health state. Its deployment policy embeds the exact transport policy, lists the
candidate IDs that count as healthy, and fixes decision age and future-skew
limits. This keeps a selected backup route distinct from normal operation without
assuming that every deployment has the same primary bearer.

A fresh selected or acknowledged healthy candidate is `healthy`. A fresh route
outside that set, `store_and_retry`, or an unavailable decision is `degraded`.
Pending and unknown acknowledgements remain `unknown`; stale and excessive-future
decisions also remain unknown. Exact age and future-skew equalities are accepted.

The first decision establishes a baseline. Healthy-to-degraded and
degraded-to-healthy changes emit content-identified `transport.degraded` and
`transport.recovered` events. A rule edit emits `transport.recomputed`. Duplicate
and historical decisions cannot replace the canonical decision. Live and replay
produce the same state and event identities; replay prohibits physical Action
dispatch, and live results still require separate authorization.
