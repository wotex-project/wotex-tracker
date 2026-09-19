# WTR.15 Tracking application and mobile companion

## Status

Accepted target contract. A partial shared browser workflow exists; no complete
application, mobile build or device acceptance exists.
The asset page can read declared scalar Properties from the authorized committed
service snapshot and discloses that the read does not contact the device.
The browser overview now reads each asset's latest authorized committed state
separately, showing retained measurements and position claims with their source,
uncertainty, clock and quality or an explicit unprovisioned/unavailable state.
Asset details and retained state history expose the same redacted positions while
keeping multiple claims distinct. They do not claim live connectivity, fusion,
canonical selection or an inferred route. Each
provisioned card also lists the committed status of the asset's defined rules and
marks low battery or overdue reporting as needing attention.
The asset detail can export the currently displayed bounded state-history page
as JSON after reauthorizing and matching its committed snapshot. This is a
page export. It can also traverse and export a complete retained state history
when it fits 1,000 rows and 1 MB, reauthorizing every page and rejecting a
changed snapshot or exceeded budget without a partial file. Larger history,
retained-data deletion and shared trip/stop presentation remain open. The
service now supplies dedicated, snapshot-pinned pages of each Thing's retained
trip start, stop and interruption events without letting unrelated alerts
consume the page bound. The browser now
uses the service's bounded snapshot-pinned route pages, displays exact points and
explicit missing, ambiguous and rejected-position gaps, and plots only separate
page-local segments. It supplies no basemap or road matching and never connects
segments across page boundaries. A page export reauthorizes and reproduces the
displayed identity, then downloads bounded JSON without a continuation cursor.
The browser observation page can download native capture JSON and full evidence
claims only for a current `raw` grant. It asks the authorized service again for
each download and never places raw bytes in the ordinary page. A separate
access page now shows the current principal, scope, expiry and grant categories,
explains browser sign-out, and lets an administrator revoke the current service
credential after explicit confirmation. Administrators also see the scope's
configured credentials with permissions, expiry and revocation status and can
revoke another active credential through a recoverable, confirmed operation.
Any user can also see this server's browser sessions that hold the same
credential and end the others. Accesses themselves are not recorded, so a full
access audit and management of devices remain open. An administrator can remove an enrolled asset
after reading the consequences and confirming: its enrollment, Thing, state and
rule definitions leave current views while history, evidence and alerts remain.
Data deletion and retention management remain open.
An Activity page lists the changes committed with the browser's credential in the
last seven days, newest first, with links to the changed records, so work can be
found after an operation reference is lost.
Readers can move forward and revisit up to 32 earlier state-history pages;
each move reloads that page under current read authority. Refresh starts again
at the latest snapshot. Temporary failures keep the current page available;
an earlier page from a changed snapshot requires refresh.
The asset overview, setup and association observation lists likewise retain up
to 32 earlier page requests, reloading each page under current authority. A
failed refresh keeps the current page and its back path until a new first page
loads. Returning to a page from a changed list snapshot requires refresh.
A Protection page lists each committed deterministic rule status through the
read-only service projection: heartbeat, battery, transport health, motion and
trips, and geofence membership. Each rule page shows its thresholds, timing and
retained evaluation history under current read authority. It omits position
evidence. An administrator can add a heartbeat or low-battery-voltage rule to a
provisioned asset with a recoverable operation reference, then edit or delete
it from the rule page; the service evaluates it from committed evidence. The
asset's protection page lists its live definitions at one committed snapshot for
any reader and offers no new rule once the asset has eight. It also pages the
alerts of those definitions newest first.
Recorded rule events appear as newest-first alerts, and an administrator can
acknowledge a live alert once without changing the rule or dispatching an
Action. Administrators can create and exactly edit movement/trip and circle or
polygon geofence rules. Arming and notification delivery remain open.
These are required product deliverables and optional installations for consumers
of the library. An incomplete backend or UI framework cannot waive a product gate.

## Product and authority

The product MUST ship a complete personal asset-tracking application, with a
smart-bike configuration, over the public service in WTR.07. Other assets and
third-party frontends use the same domain contracts. Bike terminology, display
preferences and rule configuration belong to the application/profile; generic
identity, observations and WoT affordances must not assume a bicycle.

The bike-mounted tracker and its configured service supply tracking evidence.
The phone is a companion with explicit local capabilities; installing it neither
transfers canonical authority to the phone nor makes phone presence necessary
for independent tracker reporting. Phone-originated location, when enabled, is
a separately enrolled source with consent, provenance and its own qualification.
It must not silently replace the asset position or imply background collection.

The application MUST support the following workflows without developer tools:

| Workflow | Required behavior |
|---|---|
| Setup | Select operator-controlled infrastructure, authenticate, enroll/associate a tracker, inspect identity evidence and finish provisioning; recover from failure without duplicate enrollment |
| Overview | List owned/authorized assets; display current or last-known position, age, uncertainty, battery, motion, connectivity and armed state; distinguish unknown, stale, unavailable and unsupported |
| Find and inspect | Interactive map, asset details, source evidence, last contact and qualified local connection; no location invention when GNSS, network or map content is unavailable |
| History | Bounded route replay, trips/stops, event timeline, time-range selection, units/timezone controls and authorized export; expose gaps and rejected/suspect positions |
| Protection | Configure geofences and deterministic movement/tamper/heartbeat/low-battery rules; arm/disarm with authorization; explain triggering evidence and acknowledge alerts |
| Interaction | Read Properties and invoke qualified configuration/Actions through the public service; show queued, denied, failed and unknown outcomes without presenting dispatch as device success |
| Analytics | Ask questions, explore live graphs, change filters and save dashboards under WTR.16; ordinary dashboards and structured queries work with AI absent |
| Privacy | Inspect access, revoke sessions/devices, unpair, unenroll, export/delete retained data and manage retention; display the consequences before a destructive operation |
| Recovery | Reconnect, resume after process/device restart, resolve stale writes and display pending/unknown work; preserve the last valid state |

Capability-aware presentation MUST preserve valid sensor-only and headless uses.
An unsupported sensor must not gain fictitious controls to fill a screen. The
smart-bike product gate nevertheless requires actual qualified hardware covering
its required positioning, battery, movement and local provisioning workflows;
showing every required capability as unavailable does not pass that gate.

## Shared implementation and host layout

Use independent Mix projects, not an umbrella that makes every consumer compile
all hosts. The planned layout is:

- root `wotex_tracker`: headless domain library;
- `packages/tracker_service/`: reusable service components, explicit child specs,
  authorization and storage seams, and the WTR.07 machine interface;
- `packages/tracker_ui/`: shared Phoenix LiveView/HEEx components, screens and
  presentation functions, without an application startup callback;
- `hosts/app/`: server/release composition of the service and optional UI;
- `hosts/nerves/`: bootable service and display composition under WTR.14; and
- `hosts/mobile/`: mobile shell, local presentation runtime and OS integrations.

Create each project when its executable milestone requires it. The shared service
does not import UI, and the shared UI imports no host. Shared first-party packages
follow WTR.00 instance/configuration rules. A host starts only its own composition,
never another host's application tree. Root archive contents exclude these projects.

Browser, Pi kiosk and mobile WebView MUST reuse the same LiveView screen/component
implementation for overview, history and analytics. Responsive layout and
capability-dependent controls are allowed. Domain presenters expose explicit
values and intents; LiveView assigns, map hooks and native view state hold only
projections. No generic cross-platform widget framework or duplicate policy
engine is required. A React consumer uses the machine contract rather than
depending on these Elixir modules.

Service access has an explicit local or remote implementation. Server/Pi hosts
can call the authorized service in-process; mobile uses the versioned remote API
and a bounded local cache. Both paths MUST preserve identity, authorization,
errors and commit outcomes. A local presentation endpoint is not a second
authoritative observation store. Local phone observations submit through the
same admission contract when that collection capability is enabled.

## Mobile rendering and native capabilities

The required architecture is a native mobile shell hosting the shared web UI.
Use Phoenix LiveView locally on the phone with a loopback WebView so cached
inspection and navigation do not depend on a live remote LiveView connection.
Mob is the first implementation candidate; selecting it is contingent on the
gates below. Small platform-native bridges may fill required capabilities.
Native rendering of individual controls is permitted when needed, while the
required shared workflows remain LiveView. A framework's native-looking template
syntax does not establish HEEx compatibility.

The initial mobile target is iOS on a physical iPhone. Other mobile platforms
must pass their own gates before support is claimed. Pin the shell, plugin,
Elixir/OTP, native SDK, OS floor and packaged assets as one tested cohort.
The mobile host may require a newer runtime than the library; it MUST NOT raise
the core's supported floor or require mobile tooling in root consumers.

Required native integrations are secure credential custody, notification
registration/tap routing, app lifecycle, permitted BLE central scan/connect/
read/write for local provisioning, and OS sharing of authorized exports. A
peripheral-only BLE API does not satisfy central support. Reusable BLE protocol
and WoT mapping work belongs to `wotex_ble`; a mobile shell owns the platform
bridge and permission lifecycle. No duplicate generic BLE stack belongs here.

Credentials MUST use platform secure storage, not ordinary preferences, JS
storage or files presented as a keychain. Test sign-out, revocation, server
switching, backup/restore and unavailable secure storage. The bridge exposes a
closed, versioned, bounded operation schema with request IDs and origin/session
binding. No arbitrary native method, executable code, module name, URL or
filesystem path can be supplied through page content.

Bind the local presentation endpoint to loopback and require an app-session
capability plus origin/CSRF protections. Loopback is not authentication. Limit
navigation and bridge access to the packaged application; external links open
without bridge privileges. Ship no development distribution listener, hot-code
endpoint, development cookie or untrusted remote executable assets. Production
assets and native plugins are identified by the mobile artifact manifest.

## Offline and lifecycle behavior

The companion MUST open previously synchronized overview/history/dashboard data
without remote connectivity and label its age and completeness. An empty cache
has an honest first-use state. Cached map coverage is explicit; missing tiles
do not hide retained coordinates or invent a background map. Pan/zoom, history
inspection and structured local views remain usable on retained data.

Suspend, process death, reboot and network switching must be ordinary tested
states. Reconnect through WTR.07 cursors and resnapshot when retention has expired.
Persist only bounded cache and permitted pending work. Service-side policy is
re-evaluated at execution; cached authorization never grants new authority.
Physical Actions are not silently queued offline or replayed after reconnect.

Notifications carry a minimal opaque event reference, not location, credentials
or raw evidence by default. Opening a notification re-authenticates/authorizes
and resolves the current event; expired, deleted and revoked events have explicit
results. Test cold, warm and background starts, duplicate/old taps, token rotation
and invalid-token removal. Provider acceptance, OS delivery and user reading
are distinct outcomes; push is not the canonical event log.

Mobile OS suspension can stop the local BEAM. No GenServer, socket or audio
keep-alive workaround may be treated as a background tracking guarantee. Any
phone-location collection requires a separate foreground/background capability
contract, consent, declared OS modes and physical lifecycle/energy evidence.
Notification permissions or network denial must not disable independent tracking
on the bike/service or erase local history.

## Distribution and funding

Provide a documented local Xcode build/test path and a reproducible signed
distribution path. Under Apple's current account rules, free Personal Team
provisioning is for personal testing and expires after seven days. Normal
TestFlight/App Store distribution requires program membership; the listed
annual price is USD 99 or local equivalent. A free/non-commercial app alone
does not qualify for a fee waiver; eligibility requires an appropriate legal
organization and Apple's approval. Recheck these external requirements before
distribution. [Account rules](https://developer.apple.com/help/account/basics/about-your-developer-account),
[enrollment](https://developer.apple.com/programs/enroll/),
[fee waivers](https://developer.apple.com/help/account/membership/fee-waivers).

Distribution requires account ownership, signing authority and any necessary
funding. Sponsorship may cover those costs; it is not itself a prerequisite or
a Tracker runtime service, and it does not lower acceptance requirements.
An unfunded/unavailable distribution lane remains blocked; it is not complete.
The web application remains independently usable. External build/distribution
services are optional and must not be needed to build or operate the product.

Native integration must provide useful application behavior beyond displaying a
remote website. Signed build success does not establish store acceptance;
submission and review are separate, authorized operations under the current
[App Review requirements](https://developer.apple.com/app-store/review/guidelines/#minimum-functionality).

## Hard acceptance gates

The application gate requires every workflow above through the public service,
including denied/revoked access and disconnected operation. The mobile gate
additionally requires a real iPhone, secure storage, real BLE central provisioning,
cold-start notification routing, cache/reconnect and signed install evidence.
Mock plugins, a simulator or an upstream demo do not satisfy physical gates.

Run one integrated scenario with the same qualified tracker on web, Pi touch
panel and iPhone: enroll, receive a position, inspect history, explore/save a
graph, trigger a deterministic alert, disconnect/resume, revoke access and
recover after restart. Compare canonical identity, units, query generations and
event IDs across the surfaces and an independent non-Elixir API consumer.

Verify screen-reader semantics, keyboard/touch navigation, focus, font scaling,
contrast and map/chart alternatives on each surface. No required workflow may
depend solely on color, hover or drag. Test unavailable native capabilities as
well as successful real use. Record cold/warm startup, input-to-render latency,
stream load, peak RSS, allocation and phone energy under stated conditions.
Fix acceptance budgets for the selected devices before qualification; document
failures and improve the implementation instead of weakening requirements.
