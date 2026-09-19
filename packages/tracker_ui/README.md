# WoTEx Tracker UI

Shared LiveView screens over the authorized Tracker service. This package has
no application callback, endpoint, listener or automatic session store.
Hosts own and explicitly supervise those resources.

The first workflow covers sign-in, bounded asset and observation lists,
single-file Observation JSON capture import in Setup, evidence inspection,
confirmed enrollment, later observation association, explicit Thing updates,
retained measurements, resource history and per-asset measurement graphs with
an exact table. Retained position projections appear on overview, asset-detail
and state-history surfaces when supplied; an empty collection remains explicit.
An asset route screen submits the service's closed replay policy, draws only its
page-local segments in a coordinate plot and pairs them with exact points,
rejections, exclusions and gap details. The screens do not choose a canonical
source, road-match a route or claim current connectivity. Unsupported positioning
and Actions are identified honestly.
The asset page reads declared scalar Properties from the authorized committed
service snapshot, with no physical-device freshness claim.
Asset cards now read each latest committed state separately. They show retained
measurement values, position source/uncertainty and provenance, distinguish
unprovisioned from temporarily unavailable summaries, and make no
live-connectivity claim. The asset page retains each position claim separately
with qualified fix/receiver times, and state history shows the same redacted
projection beside measurements.
Provisioned cards also list the committed status of each defined rule, read in
one snapshot per asset, and mark low, overdue, degraded or outside statuses as
needing attention; a failed status read keeps the readings visible. The
protection page shows the same status beside each definition.
Readers can list retained saved definitions and rerun them under current
authorization. An administrator can save a displayed query with a fixed or
rolling window, edit or delete it, and combine compatible saved series into a
new exact-table dashboard.
The Protection page lists the committed status of heartbeat, battery,
transport-health, motion and geofence rules through the read-only service
projection, and each rule page pages its retained evaluation history. These
pages show no position evidence and cannot arm or acknowledge a rule.
A provisioned asset's protection page lists its live rule definitions with
their revision and stored settings, linking each to its rule status. An
administrator can add a heartbeat, low-battery-voltage, motion/trip or geofence
rule there until the asset has eight definitions. Motion and geofence forms keep
event-time, lateness, sequence, uncertainty and gap choices explicit; geofences
accept closed circle or polygon geometry. Position rules state that a bundle must
contain exactly one position because this UI does not invent source selection.
The same page lists, newest first and ten at a time,
the alerts recorded by those definitions, with a bounded path back to newer pages. The form captures the scope generation, keeps an operation
reference in the address, derives the rule ID from it and verifies the saved
definition's asset before reporting success. The service evaluates the rule;
the page sends no notification. A rule page shows its service definition and
lets an administrator prepare an edit or deletion with the same generation check
and recoverable operation reference. Parameters that cannot round-trip exactly
through the browser fields are not offered for editing, so a save cannot silently
round or replace policy content.
The Protection page links to a newest-first alert list. Each alert page shows
the recorded status change, rule, the asset of a defined rule or that the host
manages the rule, evaluation mode and dispatch restriction, and
lets an administrator acknowledge a live alert once through a prepared operation
reference. Replay alerts are marked as needing no review.
The Activity page pages the changes committed with the browser's credential in
the last seven days, newest first, describes each from its receipt data and
links the asset, observation, dashboard or alert it changed.
This is not full application, Pi or mobile acceptance.

`Wotex.Tracker.UI.Local` calls only the public authorized service facade.
For Property reads it creates a bounded Runtime request context before calling
that facade.
`Wotex.Tracker.UI.Sessions` keeps bearer credentials in bounded server memory;
browser cookies and LiveView session payloads carry an opaque session identifier.
Every service request rechecks authority. Logout destroys the presentation
session; service credential revocation also rejects existing views. The Access
page lists the live browser sessions on this server that hold the same
credential and scope, by start and expiry time, and ends another one on request
without revoking the credential; session identifiers never reach the page. The Access
page lets an administrator revoke their current service credential with a
generation check and explicit confirmation. An uncertain commit redirects to
sign-in with the operation reference so it survives the revoked session.
Administrators also see the scope's configured credentials with principal,
permissions, expiry and revocation status, and can revoke another active
credential. That flow keeps the credential ID and an operation reference in the
address, requires confirmation and counts a committed receipt only after the
reloaded inventory shows the credential revoked.
An administrator can remove an enrolled asset from its detail page. The removal
page states that the asset, its state and its rule definitions leave current
views while history, evidence and alerts remain, then requires a prepared
operation reference and confirmation. Success is reported only when the receipt
names the asset and its enrollment is no longer readable.

The host supplies a `Wotex.Tracker.UI.Client` implementation and explicitly
starts the session store. The local adapter resolves the current service for
each request, so a restarted store is not cached in a view. The standalone app
host owns the endpoint, PubSub, session supervision and private listener
configuration; this package imports no host modules.

Capture import, enrollment, association and provisioning acquire a stable operation reference
in the page URL before exposing a submit control. Reconnect checks the durable
receipt, including its resource identity. An unknown outcome is shown explicitly
and does not permit an automatic repeat. Setup accepts one `.json` file of at
most 256 KiB and passes its decoded Observation envelope to the authorized
service admission contract. It does not scan a device or create a capture.
Views retain only bounded presentation snapshots; authority and canonical state
remain in the service.

Run the complete local gate from this package directory:

```sh
WOTEX_PATH_DEPS=1 MIX_ENV=test mise exec -- mix deps.get
WOTEX_PATH_DEPS=1 MIX_ENV=test mise exec -- mix check --no-retry
```

Phoenix and LiveView JavaScript assets are served locally from the pinned
dependencies. The small repository hook reports disconnection and loading;
there is no separate JavaScript framework or asset-build runtime. The ordinary
package archive contains its Elixir modules, CSS and hook, with no endpoint or
test helpers. Root and service-only consumers do not depend on this package.

The first cohort exercises real authorized services, duplicate prevention,
lost-reply recovery, revocation, read-only denial, upload bounds, bounded
lists/history, CSRF protection and credential custody. Device discovery and
capture, basemaps, trip history, remaining rule workflows, interactions, remaining privacy controls,
remote adapters and cross-surface accessibility remain subsequent work. A
responsive browser view does not qualify a mobile or Pi application.

The route-history screen defaults to a one-day UTC window ending after the
latest retained asset state. Readers can choose trusted-fix/receiver fallback,
valid/suspect quality, adjacent time/distance gaps and a bounded page size. Its
SVG uses separate paths for service segments and the short antimeridian delta;
it has no basemap and makes no claim between recorded points. Missing or
ambiguous materialisations and rejected samples remain visible. Previous/next
navigation reloads every page under current authority, retains the displayed
page on temporary failure and never connects coordinates across pages.

The analytics screen builds a closed absolute UTC query for one retained asset
using a currently recorded numeric measurement and unit. It restricts the
aggregation and bucket vocabulary, delegates validation and execution to the
authorized service, and shows the snapshot, qualified/excluded counts and only
observed buckets. Line, area and point views keep gaps separate, expose exact
bucket details in the table and offer keyboard-accessible time-window controls.
The quality selector allows valid, suspect, or both admitted qualities; invalid
readings remain excluded. A saved query retains the selected quality filter.
The save control prepares a stable operation reference in the URL, captures the
current scope generation and submits the admitted query plus visualization
through the authorized service. The window policy can be a fixed time range rerun on the latest
data, a rolling window, or an incident snapshot of the exact displayed result;
the service refuses a snapshot when a commit superseded the displayed result. It verifies a committed receipt against the
saved definition's asset series and suppresses duplicate writes after an
uncertain reply. After a successful unsaved query, any reader can opt into
follow mode. It checks the committed scope cursor every 5 seconds, reruns only
after a commit and preserves the selected duration while moving the absolute UTC
window to the asset's newest retained state. A temporary failure retains a
marked stale result for retry; current denial clears it. Manual queries and
historical navigation stop following. General dashboard composition and a
recorded live public-provider prompt run remain open. An administrator can also
edit a saved dashboard's title and view or delete it with a generation check and
recoverable operation receipt.

An enabled host also exposes administrator-only operational history. Its closed
one-, five- and fifteen-minute windows plot discrete telemetry measurements by
elapsed UTC time without joining samples. The collector response pins the epoch,
window and high-water mark across exact 25-row table pages. The graph is capped
at 1,000 retained samples and visibly reports any earlier matching samples that
remain available through those pages.
Saved dashboard pages can follow committed changes while open. They check the
scope's committed event cursor every 5 seconds and rerun the query only after a
commit, from a snapshot cursor taken before the run; a rolling window also
reruns every 30 seconds. A failed check or run keeps a marked stale result and
retries on each later check, and the result clears immediately when the
definition or read grant disappears. Push delivery without polling and
cross-surface acceptance remain open.
Executed analytics and saved-dashboard results can be downloaded as their exact
closed JSON documents, including snapshot and result identity, time bounds,
units, exclusions and gap policy. The browser creates the file locally from the
current authorized LiveView result rather than making a new query.
The Dashboards page also lets an administrator select two to eight compatible
saved definitions. Their measurement, unit, query settings and window must
match, and their series must be distinct. A generation-checked save creates one
new multi-series query with an exact table. Its stable operation reference
supports recovery after a lost reply; a reader can run but cannot create it.
Editing that definition to a line, area or points view plots its series on one
scale. Each series retains an exact table, and absent buckets remain gaps.
Any reader can also switch the displayed saved result among table, line, area
and points without changing its definition or rerunning the query.
