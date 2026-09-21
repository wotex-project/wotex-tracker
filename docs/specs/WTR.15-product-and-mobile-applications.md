# WTR.15 Tracking application and mobile companion

## Status

This contract inherits WTR.12's independent completion axes and WTR.13's
greenfield Zig policy. Missing Apple account, signing, device or registry access
never blocks locally executable implementation.

Accepted target contract. The shared browser workflows and their local
accessibility acceptance are complete. The mobile software build has a bounded
local development lane, while signed-device and distribution acceptance remain
separate and incomplete.
The asset page can read declared scalar Properties from the authorized committed
service snapshot and discloses that the read does not contact the device.
The browser overview now reads each asset's latest authorized committed state
separately, showing retained measurements and position claims with their source,
uncertainty, clock and quality or an explicit unprovisioned/unavailable state.
It separately shows armed, disarmed, unknown, unavailable or unsupported arming
state and never treats a missing fact as disarmed.
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
retained-data deletion remains open. The
service now supplies dedicated, snapshot-pinned pages of each Thing's retained
trip start, stop and interruption events without letting unrelated alerts
consume the page bound. The browser presents those events newest first with UTC
window inputs and selectable fixed-offset effective, confirmation and recording
times. The default window covers 30 days through the latest retained state;
intervals can be shown as exact milliseconds or decimal seconds. Fixed offsets
are explicitly not daylight-saving-aware. It pairs a start and ending only when
both are visible on the same page, never invents a missing stop or joins across
pages, and reauthorizes a bounded cursor-free page export that records its window
and presentation choices. The browser now
uses the service's bounded snapshot-pinned route pages, displays exact points and
explicit missing, ambiguous and rejected-position gaps, and plots only separate
page-local segments. It supplies no basemap or road matching and never connects
segments across page boundaries. A page export reauthorizes and reproduces the
displayed identity, then downloads bounded JSON without a continuation cursor.
The service separately exposes an authorized, bounded final distance summary for
an immutable completed trip. It reconstructs at most 100 exact retained samples
under the motion policy committed at trip start, returns centre/lower/upper
metres and every segment exclusion, and releases no private evidence identities.
Each stop or interruption in the shared browser links to a dedicated summary
screen. It validates the complete closed projection, presents exact canonical
metres and each included or excluded segment, retains a valid result across a
temporary failure and reauthorizes an identity-matched bounded JSON export.
Readers can select a closed fixed UTC offset and metre, kilometre or
international-mile presentation. Converted distance is display-only and rounded
to three decimals; canonical metres remain visible, and export records the exact
offset, conversion and rounding declaration.
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
Action. Suspicious-movement alert details explain the reviewed trigger conditions:
confirmed movement and armed state plus explicit owner absence or the rule's
unknown-as-absent interpretation. They label those conditions historical and
keep private fact/evidence identities out of the page. Administrators can create and exactly edit movement/trip and circle or
polygon geofence rules. The service can now commit and read a private-fact-backed
armed or disarmed state without claiming device contact. An asset with a motion
definition links to a dedicated shared arming screen. Administrators prepare an
armed/disarmed change with a current-generation check, stable recoverable
operation reference and explicit confirmation; readers can inspect but not
change it. A committed result is verified against the exact Thing and state, and
the screen never presents the service commit as a device change or notification.
The same screen presents the reviewed public owner-presence state and its times,
or an explicit unknown when no fact exists. It does not infer absence from radio
silence and offers no control that could manufacture owner-presence evidence.
Administrators can create, review, exactly edit and delete an event-only
suspicious-movement definition bound to a live motion definition. Definition,
motion, arming and owner-presence mutations reevaluate exact bindings atomically.
The service now provides principal-isolated APNs endpoint registration with
encrypted token custody, rotation and removal. Live alert creation atomically
stages a minimal opaque alert reference per endpoint, while replay alerts stage
nothing and queue overflow cannot erase canonical alert history. Native
registration, provider dispatch and notification tap routing now have a complete
local peer lane with token rotation, invalid-token removal, provider failures and
cold/warm/background opening. Apple provider, OS delivery and user-reading claims
remain separate physical qualification evidence.
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

Zig owns the mobile build graph, generated C-ABI/static-NIF tables and any new
bounded native helper that does not require an Apple object-framework lifecycle.
UIKit, WebKit, CoreBluetooth, Keychain and notification delegate integration
remain Objective-C or Swift where that preserves typed framework calls, ARC and
delegate semantics. Do not replace those APIs with manual Objective-C runtime
messaging merely to increase the Zig line count. A platform plugin may migrate
to Zig only after the Mob/native build seam supports it and simulator plus device
receipts prove equal lifecycle, error and memory behavior.

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

## Local development versus Apple qualification

Apple account and device prerequisites never suspend implementation. Before any
paid membership, registry setup or physical-device session, the development lane
MUST complete all repository-owned work that can run locally, including:

- the complete shared mobile workflows and target-specific TAT140 setup UI;
- closed BLE bridge commands, permission states and deterministic local peers for
  scan/connect/read/write success, denial, timeout, disconnect and malformed data;
- secure-store success/unavailable/rotation/revocation contracts using the iOS
  simulator or bounded native test host;
- local APNs registration/provider/tap simulation covering token rotation,
  invalid tokens, duplicate/old taps and cold/warm/background routing;
- offline cache, process death, reconnect, SSE resume and lifecycle simulation;
- simulator builds, packaged-asset manifests, accessibility checks and automated
  screenshots for every UI state; and
- unsigned/local artifacts and scripts needed to reproduce those checks.

The qualification lane then uses a real iPhone and the selected TAT140 or its
explicitly associated provisioning component to verify actual CoreBluetooth,
Keychain, lifecycle, energy and notification behavior. The distribution lane is
separate again: Developer Program enrollment, App ID and entitlement registration,
certificate/profile or API-key custody, TestFlight/App Store upload and review.
An external lane may remain pending, but no locally executable item may be listed
under it or deferred because that account/device is absent.

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

Plan the enrollment lead time rather than treating payment as immediate
capability. Individual enrollment requires an Apple Account with two-factor
authentication, current legal/contact details, identity verification and a
valid payment method. Apple permits the agreement and purchase during individual
enrollment and directs applicants to contact support if membership confirmation
has not arrived within 24 hours after purchase. Allow at least that day when
scheduling physical acceptance. An invitation to an existing paid development
team may avoid a separate enrollment, provided that team grants the required
signing and capability access. [App enrollment](https://developer.apple.com/help/account/membership/enrolling-in-the-app),
[program enrollment](https://developer.apple.com/help/account/membership/program-enrollment).

Organization enrollment additionally requires a recognized legal entity,
binding authority, a work-domain email and website, and normally a D-U-N-S
number. When a new D-U-N-S number is needed, Apple documents up to five business
days for issuance and up to two further business days for the data to reach
Apple; Apple's organization review follows and has no promised completion time.
Do not schedule organization enrollment as a same-day prerequisite.
[D-U-N-S requirements](https://developer.apple.com/help/account/membership/D-U-N-S).

Free Personal Team signing can exercise an installed build on the owner's phone,
but Apple's iOS capability table does not make Push Notifications available to
that membership class. Firebase, OneSignal and similar intermediaries do not
remove APNs signing and entitlement requirements. After paid team access becomes
active, configure the explicit App ID, Push Notifications capability, APNs
provider key or certificate and development provisioning profile before running
the physical delivery/tap test. For planning, reserve one to three hands-on hours
for this setup and an already-implemented smoke test. That estimate is not an
Apple service-level promise and excludes implementation of the mobile shell or
notification dispatcher. [Supported iOS capabilities](https://developer.apple.com/help/account/reference/supported-capabilities-ios),
[APNs authentication](https://developer.apple.com/help/account/capabilities/communicate-with-apns-using-authentication-tokens).

Distribution requires account ownership, signing authority and any necessary
funding. Sponsorship may cover those costs; it is not itself a prerequisite or
a Tracker runtime service, and it does not lower acceptance requirements.
An unfunded/unavailable distribution lane remains pending; it is not complete.
The web application remains independently usable. External build/distribution
services are optional and must not be needed to build or operate the product.

Native integration must provide useful application behavior beyond displaying a
remote website. Signed build success does not establish store acceptance;
submission and review are separate, authorized operations under the current
[App Review requirements](https://developer.apple.com/app-store/review/guidelines/#minimum-functionality).

## Hard acceptance gates

The development application gate requires every workflow above through the
public service and local simulator/peer lanes,
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
