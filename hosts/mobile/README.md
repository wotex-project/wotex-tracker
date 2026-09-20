# WoTEx Tracker mobile host

This independent host will compose the shared LiveView UI, its versioned remote
service client and narrow iOS integrations inside a Mob WebView. Its native
cohort is Elixir 1.20.1, OTP 29.0, Mob 0.9.1, MobDev 0.7.1 and the exact Zig
development build pinned in `mise.toml`. Those versions match Mob's downloaded
iOS runtime; the root library and other hosts retain their independent floors.

The first executable seam is the bounded offline projection cache. It stores no
bearer credential, access proof, raw evidence, mutation or physical Action. A
cache binding includes the canonical HTTPS origin, principal, scope, credential
ID and a secure-storage installation ID. Switching any binding field purges the
previous account. Entries expire at both their local retention deadline and the
last remotely observed credential expiry. Reads report synchronization age and
completeness and never authorize a remote request.

The cache database belongs under Mob's app-private cache directory and is safe
to lose: an absent or OS-purged cache is an explicit first-use state. The host
must reconstruct the binding from platform secure storage after process start;
ordinary files, preferences and browser storage are not credential stores.

The optional `:map_pack` startup value is a decoded `wtr.map-pack.v1` document,
specified by the repository's `docs/contracts/map-pack-v1.md`. Startup admits
its closed coverage, attribution and bounded line work before passing it to the
loopback endpoint. It is packaged/operator content, not an account cache entry;
it carries no service credential or retained route and causes no network fetch.

The executable presentation seam runs the shared LiveView router behind a
numeric IPv4 loopback-only Bandit listener. A fresh 32-byte capability appears
only in the initial WebView bootstrap URL; the endpoint replaces it with an
encrypted, signed, HTTP-only, SameSite-strict cookie and requires its digest on
every later HTTP and LiveView admission. Login, logout and session renewal retain
only that host-owned binding. The WebView allow-prefix is the exact local origin,
foreign WebSocket origins fail, external canonical HTTPS links open through the
OS, and no development distribution listener or cookie is configured.

The committed native bootstrap no longer depends on developer-supplied host
options. On first launch it renders a native setup screen that accepts only an
exact canonical HTTPS origin. It stores that non-secret selection as a bounded,
versioned JSON document in a singly linked `0600` file under an app-private
`0700` directory. Credentials, notification tokens, capabilities and signing
secrets never enter that document. Every process start generates a new local
port, capability and Phoenix signing secret, dynamically starts the loopback
host, then mounts the sole bridge-bearing WebView. A changed service origin is
rechecked by credential restoration, which purges a foreign credential and its
account-bound cache before presenting a session.

Remote calls remain bounded by the shared client and its exact configured HTTPS
authority. The mobile transport invokes Mob's OS DNS seam before Mint without
allowing resolution to rewrite the authority or request. On ordinary development
hosts, where the Mob NIF is intentionally absent, the transport falls back to
the BEAM resolver so the same closed request path can be tested.

The host-local `wotex_mobile_secure_store` Mob plugin supplies only a credential
envelope slot and an installation-ID slot. Its iOS NIF uses generic-password
Keychain items with `AfterFirstUnlockThisDeviceOnly` accessibility and explicitly
disables synchronization. The BEAM wrapper bounds values to 4 KiB, contains
native failures and has no ordinary-file or preferences fallback. The plugin is
explicitly acknowledged as app-owned native code in the committed Mob config.

Successful mobile sign-in now commits the exact bounded credential envelope to
that secure slot before the volatile browser session is issued. The envelope's
authenticated origin, principal, scope, credential ID, expiry and installation
ID bind the offline cache. A cold host start reauthorizes the stored credential,
creates a new volatile browser session and places only its opaque identifier in
the loopback cookie. If the service is unavailable, an unexpired bound envelope
may instead create a fresh read-only local session. That session exposes no
enrollment, ingestion, raw-evidence or saved-query management capability and
can read only exact previously synchronized projections. Revoked, expired,
malformed or foreign-origin credentials are removed with their cache. Sign-out
clears both and remains retryable if either boundary is unavailable.

The mobile client writes successful overview, history, dashboard and route-map
reads through to the account-bound cache. Only a service-unavailable response
may fall back to the exact request key; remote authorization denial always wins.
Every fallback carries visible offline source, synchronization time, age,
completeness and access-expiry metadata. Shared browse, asset, trip, route and
dashboard views render that state explicitly. Mutations, raw evidence, access
management and operation recovery are never cached or queued.
The shared Interactions route is therefore online-only: conservative offline
identity denies the `interact` grant, invocation is never queued, and durable
Action status is never replaced by a cached projection.
The shared owner-presence admission is also online-only: conservative offline
identity denies administration, no private fact or public presence projection is
cached, and an unavailable submission is never queued or replayed.

The root native screen subscribes only to Mob's application and network
lifecycle categories. A real background-to-active transition or recovery of an
online path reloads the local WebView once, causing normal session validation,
remote reauthorization and view resnapshot. Duplicate callbacks do nothing;
native subscription and reload failures stay contained. This is reconnect
orchestration, not a background-execution or background-location claim.

Notification support is an explicit opt-in pair of APNs application ID and
`sandbox` or `production` environment. The host pins and activates the signed
MobNotify plugin, asks for notification permission from the root native screen
and requests a provider token only after permission is granted. The token is
submitted through the current authorized session with the service's generation
check and a deterministic recoverable operation ID. Its endpoint identifier is
a one-way, domain-separated digest of the device-only installation ID. Provider
tokens are never written to the cache, Keychain envelope or process status; an
unavailable registration may retain one only in the redacted volatile registrar
until sign-in or network recovery retries it. Permission denial best-effort
removes an existing endpoint.

The notification bridge admits only the exact
`wtr.notification-reference.v1` data projection with one opaque event reference.
It percent-encodes that reference into the fixed local alert route, where the
shared UI reauthorizes and resolves current data. Extra keys, private alert data,
invalid UTF-8, malformed references and native failures produce no navigation.

Authorized JSON exports retain their ordinary Blob download in a browser. In
the native WebView, the packaged script captures only Mob's original native
message bridge before the LiveView hook replaces it and sends a fixed
`wtr.mobile-share.v1` request to the root screen. That boundary accepts only the
eight existing export filenames, `application/json`, valid JSON no larger than
1 MiB and the exact public export schema where one exists. It then opens Mob's
text share sheet with the authorized JSON content. No URL, path, file read,
fetch, native method name or arbitrary plain text crosses the bridge.

Because the pinned first-party Bluetooth plugin exposes only the peripheral
role, the app-owned `wotex_mobile_ble` plugin supplies the required iOS
CoreBluetooth central transport boundary. Packaged UI can issue only the exact
versioned scan, stop, connect, disconnect, filtered-discovery, read and confirmed
write commands through the current root screen. Scans require one to eight
service UUIDs and a deadline of at most 30 seconds; every other native operation
has a fixed 30-second deadline, and values are capped at 512 bytes. Results are
projected back as bounded versioned browser events. The bridge neither selects a
device nor implements a tracker protocol, identity decision, persistence or WoT
mapping; those require a separately qualified profile and the upstream
`wotex_ble` boundary.

Run the software gate with the host-pinned toolchain:

```sh
WOTEX_PATH_DEPS=1 MIX_ENV=test mise exec -- mix deps.get
WOTEX_PATH_DEPS=1 MIX_ENV=test mise exec -- mix check --no-retry
```

## Native iOS build path

The committed `ios/` tree contains the Mob simulator/device Zig builds, scene
bootstrap, APNs token forwarding and exact `org.wotex.tracker` bundle metadata.
It intentionally declares no audio background mode or microphone permission.
Plugin manifests add only CoreBluetooth, Security and UserNotifications during
the native build. The app's Erlang entry calls
`Wotex.Tracker.Mobile.MobApp.start/0` directly. The checked-in iOS C driver
table fixes the exact static NIF cohort required by Mob's distribution build;
the Android table emitted by the generator is ignored because this host is
iOS-only.

Machine-specific paths and Apple signing values remain in ignored `mob.exs`:

```sh
cp mob.exs.example mob.exs
mise install
WOTEX_PATH_DEPS=1 MIX_ENV=dev mise exec -- mix deps.get
WOTEX_PATH_DEPS=1 MIX_ENV=dev mise exec -- mix mob.doctor
```

After accepting the installed Xcode licence manually and signing into the
intended Apple team, boot a simulator or connect a named iPhone. A local native
build is then. The local entitlement file is intentionally ignored so a
development value cannot be mistaken for a production release value:

```sh
cp ios/WotexTrackerMobile.development.entitlements.example \
  ios/WotexTrackerMobile.entitlements

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  WOTEX_NOTIFICATION_ENVIRONMENT=sandbox \
  WOTEX_PATH_DEPS=1 MIX_ENV=dev mise exec -- mix mob.provision

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  WOTEX_NOTIFICATION_ENVIRONMENT=sandbox \
  WOTEX_PATH_DEPS=1 MIX_ENV=dev mise exec -- \
  mix mob.deploy --native --ios --device <device-udid>
```

Use `production` only with a production APNs entitlement and profile. Paid-team
distribution preparation begins by copying
`WotexTrackerMobile.production.entitlements.example` to the same ignored
`WotexTrackerMobile.entitlements` path and running `mix mob.provision
--distribution`. Keep team IDs, certificate names, profile UUIDs and API-key
paths only in ignored local configuration or the CI secret store.

MobDev 0.7.1's generated distribution-signing script omits `aps-environment`
even when the App Store profile contains it, so do not invoke `mix mob.release`
directly. The repository-owned release command runs that build, extracts the
embedded App Store profile, requires the exact production application/team/APNs
identity, re-signs with the minimal admitted entitlement set, verifies the
signature and signed entitlements, and only then atomically replaces the IPA:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  WOTEX_NOTIFICATION_ENVIRONMENT=production \
  WOTEX_PATH_DEPS=1 MIX_ENV=dev mise exec -- \
  mix run --no-start scripts/release_ios.exs
```

The command leaves the original IPA unchanged on profile, signing, verification,
entitlement or packaging failure. The resulting signed application must still
show `"aps-environment" => "production"` under `codesign -d --entitlements -`
before TestFlight upload. Apple signing authority remains a separate
user-managed prerequisite.

This repository has generated and software-tested the native tree, but has not
claimed a signed build. On the current machine the Xcode licence still requires
manual acceptance, and no signing team/profile or physical iPhone is available.
MobDev's published 0.7.1 constraint also predates Mob 0.9 even though the pinned
override compiles and its current native templates target Mob 0.9; a physical
build must qualify that exact override before release. The distribution
entitlement repair is software-tested but has not run against a signed artifact.
Physical notification delivery, cold/warm/background tap distinction,
secure-storage behavior, suspend/resume, network handoff, target-profile BLE
provisioning, share-sheet behavior and all other physical-iPhone evidence remain
explicitly open.
