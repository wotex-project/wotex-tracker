# WoTEx Tracker UI

Shared LiveView screens over the authorized Tracker service. This package has
no application callback, endpoint, listener or automatic session store.
Hosts own and explicitly supervise those resources.

The first workflow covers sign-in, bounded asset and observation lists,
single-file Observation JSON capture import in Setup, evidence inspection,
confirmed enrollment, later observation association, explicit Thing updates,
retained measurements, resource history and per-asset measurement graphs with
an exact table. Unsupported positioning and Actions are identified honestly.
The asset page reads declared scalar Properties from the authorized committed
service snapshot, with no physical-device freshness claim.
Asset cards now read each latest committed state separately. They show retained
measurement values and provenance, distinguish unprovisioned from temporarily
unavailable summaries, and make no live-connectivity claim.
Readers can list retained saved definitions and rerun them under current
authorization. An administrator can save a displayed query with a fixed or
rolling window, edit or delete it, and combine compatible saved series into a
new exact-table dashboard.
This is not full application, Pi or mobile acceptance.

`Wotex.Tracker.UI.Local` calls only the public authorized service facade.
For Property reads it creates a bounded Runtime request context before calling
that facade.
`Wotex.Tracker.UI.Sessions` keeps bearer credentials in bounded server memory;
browser cookies and LiveView session payloads carry an opaque session identifier.
Every service request rechecks authority. Logout destroys the presentation
session; service credential revocation also rejects existing views.

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
capture, maps, trips, protection, interactions, privacy controls, analytics,
remote adapters and cross-surface accessibility remain subsequent work. A
responsive browser view does not qualify a mobile or Pi application.

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
through the authorized service. It verifies a committed receipt against the
saved definition's asset series and suppresses duplicate writes after an
uncertain reply. This is historical inspection with explicit refresh; scheduled
subscription-driven refresh, general dashboard composition and a live
public-provider prompt run are still open. An
administrator can also edit a saved dashboard's title and view or delete it with
a generation check and recoverable operation receipt.
Saved dashboard pages offer a 30-second automatic query refresh while open,
with stale-result disclosure on temporary failure and immediate clearing when
the definition or read grant disappears. Subscription-driven updates and
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
