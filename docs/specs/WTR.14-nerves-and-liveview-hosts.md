# WTR.14 Nerves firmware and Pi control panel

## Status

This contract inherits WTR.12's independent completion axes and WTR.13's
greenfield Zig policy. Missing external prerequisites never block locally
executable implementation.

Accepted target contract. A separate headless host and Pi 5 development
cross-build now exist under `hosts/nerves/`. A separately locked kiosk source
profile reuses the shared LiveView package and has local endpoint/store-isolation
tests. A separate ARM64 QEMU image exercises first boot, an existing data
partition, private SQLite startup and loopback HTTP through Nerves. Its private
QEMU-only software peer submits one deterministic Ruuvi observation over the
authenticated HTTP boundary, verifies the decoded temperature state and replays
the same durable operation after reboot. This is virtual software evidence only.
That legacy fixture smoke MUST be replaced by a deterministic TAT140
IMEI/Codec-8-Extended peer and tracking-state assertion before the Pi development
axis is complete; no Ruuvi hardware test is planned.
Both profiles supervise a bounded Linux procfs
resource sampler beside the service; it contributes only system available
memory, BEAM-process RSS and one-minute load to volatile operational history.
The ARM64 QEMU boot gate now requires one such retained sample on both a fresh
data partition and its reboot before its serial probe can pass.
An offline create-only host provisioner now prepares the exact private service
tree for `/root/tracker` through the shared service configuration seam. It emits
only private file paths and can target mounted media without embedding the mount
path in runtime configuration. It is not media installation. An explicit
all-or-nothing direct-TLS mode validates a
bounded operator-supplied PEM chain and matching unencrypted private key, copies
them to fixed private create-only paths and writes the direct-TLS service
configuration without returning contents. It does not issue, establish trust or
renew certificates. The same command can optionally create a private loopback
browser document on a distinct port without adding UI dependencies to the
headless profile. Its version-two document binds the attached display to the
configured scope and private operator token. The kiosk authenticates the token
server-side, gives Cog only a short-lived single-use nonce and exchanges it on
loopback for an opaque HTTP-only session before redirecting to Setup. This is
authenticated software setup, not on-device credential creation or physical
display evidence. Neither Pi image has booted on a Pi. A source-level storage
marker now permits one
prepared initialization and
makes later missing, unsafe, corrupt or unsupported stores an explicit
`recovery_required` startup result. No physical storage-recovery or hardware
acceptance exists yet. A read-only offline validator now admits only a restored
private tree whose initialized marker, service instance, runtime path, supported
SQLite schema/table contract and integrity check agree, without migrating or
repairing it. The application withholds its OTP started state until that
initialized storage identity, the actual bound service listener and a writable
current-schema store pass one synchronous core-health check. The enabled Nerves
Runtime startup guard can therefore validate pending firmware only after those
criteria pass; the ten-minute heart handshake and guard's 15-minute callback
bound failure before the system reverts. Recovery and readiness acceptance
derive the current schema version and schema asset from the service owner rather
than retaining a host-local version constant. Bad-image validation and revert
still require physical target evidence. An opt-in source profile now loads the
same private, closed cellular-host document as the standalone application and
supervises the bounded Teltonika listener beside the shared service. A host
integration test proves real-socket login, two-record admission, acknowledgment,
durable inspection and joint shutdown. It does not establish a Pi boot, tracker,
SIM, carrier, firewall or encrypted-transport result.
Bootable headless and local-display profiles remain required product deliverables
and optional installations. They consume the pure library without changing its
startup or dependency contract. WTR.13 governs the root.

## Separate library and appliance

`wotex_tracker` remains a normal Mix library with no application startup callback.
`hosts/nerves/` is a separate firmware Mix application. It owns its callback,
supervisor, board configuration, network interfaces, time synchronization,
persistent data, credentials and explicitly configured Tracker service instances.
Its dependency direction is host -> Tracker -> core WoTEx values. Nothing in core
imports the host. The root archive excludes hosts and their locks/build assets.
An appliance build may opt into `/root/tracker/cellular.json`; absent that build
choice and private file, it owns no cellular socket.

`hosts/app/` supplies the server application. Both hosts consume the explicit
service components and inert LiveView/HEEx package defined in WTR.15. Firmware
must not start the server application's whole tree. Keep application callbacks,
endpoints, device/network management and deployment configuration in each host.
Shared components take explicit child specifications and service context.

The boot application may start its declared services automatically at boot; the
library never starts them merely because it is installed. Multiple Tracker
instances still take independent values/ports. A host's intentionally global
OS/network management does not become global Tracker configuration.

## Raspberry Pi 5 target

The headless baseline is `nerves_system_rpi5`; the local-display baseline is
`kiosk_system_rpi5` with Cog. The initial system candidates are 2.1.2 with Nerves
1.15.0 and `MIX_TARGET=rpi5`. Exact firmware resolution, browser/native libraries,
toolchain and target OTP MUST be recorded from the built artifact; desktop Mix
constraints do not select the embedded runtime. Pin each profile separately and
prove its compatibility rather than treating similar version numbers as identity.
Bluetooth, board EEPROM, display and update behavior need exact target evidence.
The 2.x Pi system requires firmware validation for updates to persist across
reboot. Upstream support is not Tracker hardware qualification.
[Pi 5 system documentation](https://nerves-system-rpi5.hexdocs.pm/readme.html),
[kiosk system](https://github.com/nerves-web-kiosk/kiosk_system_rpi5/tree/v2.1.2).

Begin with a headless image and admitted fixture or network/software-peer input.
Do not make onboard BLE a prerequisite for boot proof. A later BLE lane must
name the controller, firmware, bus, permissions and backend; qualify ownership,
scan bytes, reconnect and cleanup on that exact Nerves system. Reusing a desktop
BlueZ build or assuming BlueHeron support from another Pi is insufficient.
Generic BLE changes belong with `wotex_ble`, with its own native target rules.

The QEMU-only source fixture owns a random private probe credential outside the
runtime configuration. On both first boot and reboot it submits the same bounded
Ruuvi RAWv2 observation through the real authenticated loopback HTTP interface,
using one fixed idempotency key and generation-zero request. The first boot
commits it; reboot receives the durable replay. Both require the resulting
public state to contain the deterministic 24.3 °C decoded temperature before
the serial probe passes. This proves software-peer ingress, decoding, storage
and replay in the virtual image without claiming a radio or physical network.

The host uses Nerves networking/time libraries only as host dependencies. Offline
boot must expose unsynchronized time honestly and retain the explicit receiver
time/monotonic deadline distinction. Firmware/device serial numbers are private
host identifiers, not public Thing IDs. Cloud management and NervesHub are
optional; boot, local ingestion and local inspection must work without them.

The source host admits loopback startup without NTP so the provisioned local
workflow remains available offline. Direct TLS exposure instead requires
`NervesTime` to confirm synchronization in the current boot before the store or
listener starts. A persisted estimate, plausible wall time, exception or unknown
status cannot satisfy that gate. This is a conservative exposure policy, not a
hardware-RTC, long-duration drift or physical-network qualification.

The offline provisioner selects direct TLS only when listen address, HTTPS
public origin, certificate source and private-key source are all explicit. It
requires private symlink-free source custody, decodes a bounded certificate
chain and supported unencrypted key, proves that the leaf certificate and key
match, then installs verified 0600 copies at fixed runtime paths. Partial input,
malformed or mismatched material and occupied destinations fail closed, with
rollback limited to paths created by that attempt. This is configuration and
material staging, not certificate issuance, CA/hostname validation, renewal,
network reachability or on-device credential creation.

## Local control panel and remote UI

The application UI uses shared Phoenix LiveView, HEEx and Phoenix components.
No separate SPA runtime is required. Minimal JavaScript hooks may support browser-specific
features such as a map, but do not own identity, evidence, policy or canonical
state. Streams and history requests are bounded; socket assigns are projections.

Ship separate tested headless and UI-enabled build profiles. A headless artifact
contains no Phoenix/LiveView dependency, display stack or UI endpoint; its machine
API remains available under WTR.07. A UI-enabled host starts the presentation
endpoint and local browser only when selected by its explicit build/runtime
configuration. Disabling/restarting presentation must not reset ingestion or
rewrite identity. The local control panel MUST work on a physically connected
display with touch input, without a second computer or an internet connection.
An authorized browser on another device may use the same shared application.

The source kiosk's closed `wtr.browser.v2` configuration binds one scope to the
fixed private operator-token file. At display launch, the host authenticates
that token into the bounded server-held session store and passes Cog only a
random 60-second nonce. The loopback endpoint consumes the nonce once,
reauthorizes through the service, renews the encrypted HTTP-only cookie and
redirects to `/setup`. The bearer and opaque session identifier never enter the
launch URL, rendered page or LiveView assigns. Sign-out returns to manual
sign-in; credential expiry or revocation denies subsequent requests and launch
renewal. This implements authenticated attached-display setup from offline
provisioned authority. It does not create authority on the device or prove the
physical display path.

Cog displays the local endpoint full-screen. Keep its process lifetime and
restart budget separate from the ingestion service. Qualify GPU/DRM, the exact
HDMI/DSI display path, touch controller, orientation, resolution, scaling, virtual
keyboard and focus behavior. A successful HTTP response is not display evidence.
An unavailable/crashed display cannot lose admitted telemetry or repeatedly
restart the whole tracking service. Any alternative renderer must meet the same
workflow, shared-component and fault-isolation gates; it cannot waive them.

The panel MUST support initial setup, asset overview, map/history inspection,
protection settings and interactive analytics under WTR.15/16. Missing internet,
map tiles, AI or external metrics must have explicit states and leave local
tracking, cached inspection and structured analytics usable. The selected product
image includes durable storage; a volatile boot experiment is not product acceptance.

Before qualification, fix measurable boot, input-to-render, refresh, memory,
thermal and power budgets for the selected board/display/storage. Test the same
workflows with concurrent ingestion, bounded history and slow/disconnected clients.
Do not publish performance guarantees from an upstream demo or a cross-build.

Both HTTP and connected LiveView mounts enforce authentication, and every
mutation/probe/Action reaches the same service-side authorization as the CLI/API.
Revocation must affect existing subscriptions/connections. Hiding a button is not
authorization. Escape device-provided text and bound client parameters. Keep
secrets and raw identifiers out of rendered views and error messages.
[LiveView security model](https://hexdocs.pm/phoenix_live_view/security-model.html).

Refpath integration is absent/disabled by default. An enabled showcase is clearly
labelled as synthetic, private live execution, or unavailable under WTR.11.
No private module reference enters shared UI/core compilation.

## Storage and firmware recovery

The selected Nerves runtime normally uses a read-only root filesystem and a
writable application partition; its default initialization may reformat an
unmountable data partition. Therefore the default is not evidence of preserving
Tracker history after corruption. The host must choose and test a recovery policy
before advertising durable storage. Use an explicit recovery-required state for
previously initialized storage that cannot be safely read, rather than silently
claiming an empty replacement is the last valid state.
[Nerves runtime filesystem initialization](https://hexdocs.pm/nerves_runtime/readme.html#filesystem-initialization).

The source host implements that boundary with a private `wtr.storage.v1` marker
bound to the configured instance and data directory. Only a provisioned
`prepared` marker admits a missing database. After the service opens the store,
performs supported migrations and passes SQLite integrity checks, the marker is
atomically advanced to `initialized`. An interrupted transition is completed
only when both private documents match exactly apart from that state change and
the non-empty database remains present. Subsequent missing, empty, unsafe,
corrupt or unsupported storage and malformed or mismatched transitions return
`recovery_required`; startup does not delete or replace the database. This is a
software policy, not evidence that selected Pi media survives or recovers from
the physical failure matrix below.

The volatile first boot profile needs no database. A durable profile additionally
passes WTR.06 transaction/replay tests on the actual target storage. Specify data
partition capacity, full-disk behavior, write/retention limits, initialization
markers and backup/recovery procedure. Firmware rollback and application-data
rollback are separate: an older image must read the stored schema or fail with
an explicit recovery requirement. Never validate firmware solely because its UI
responds while ingestion/storage is broken.

The source recovery command checks an offline staged candidate created from the
service's SQLite-consistent backup operation. It requires the closed initialized
marker to match the configured instance and fixed runtime data path, rejects an
unfinished marker transition and SQLite sidecars, then opens the private database
read-only to check its application identity, exact current schema/table contract
and `quick_check`. It also maps direct-TLS material to its staged path and checks
its private-file policy. Its result contains no credential, storage identity or
database content. This is pre-install software admission, not proof that backup
media, copying, power interruption or physical restoration succeeds.

Updates use the chosen Nerves system's firmware validation and revert mechanism
with documented health criteria and a finite startup budget. Test bad images,
failed validation, interrupted update and restart, and preserve evidence of which
image/data generation actually ran. Operator recovery procedures must identify
destructive steps; documentation is not authority to flash or erase a device.

The source profiles enable the pinned Nerves Runtime startup guard and a
600-second heart initialization-handshake timeout; after registration the pinned
guard's callback fails at 15 minutes if startup and validation do not complete.
Tracker application startup returns only after its private initialized marker
still matches the service identity and data path, its configured listener
reports an actual bound address and port, and the live store successfully
completes a rolled-back write probe while reporting the application's exact
current schema. The check has no retry loop and collapses exceptions, exits and
malformed results to `firmware_health_failed`; the application supervisor is
stopped and its OTP started state is withheld. Because the runtime guard waits
for all expected applications before it invokes firmware validation, a pending
image cannot be accepted merely because BEAM or the UI started. This is
executable source and virtual-boot evidence of the validation policy, not proof
of a slot transition, bad-image revert or either physical deadline on a Pi.

## Acceptance matrix

| Lane | Required executable evidence |
|---|---|
| Root package | Archive consumer with no Nerves/Phoenix/LiveView/Refpath; no Tracker startup callback or implicit I/O |
| Headless firmware build | Pinned system/toolchain/dependency digests, artifact manifest, native target architecture, models included, secrets/UI/private modules excluded |
| Physical headless boot | Real Pi 5 board/EEPROM/storage record; deterministic fixture result matches desktop; service supervision and local inspection; bounded startup with network/AI absent |
| Real ingress | Exact network or BLE backend; disconnect/reconnect and owner loss; observation -> TD -> Runtime proof; unsupported radio reported explicitly |
| Local display | Real Pi/display/touch record; boot directly into authenticated setup/application; overview/history/graphs; keyboard, focus, scaling and gestures; offline operation and visible data gaps |
| UI-enabled firmware | Same service API/results; revoked-session/mutation tests; bounded streams; browser crash/restart and presentation disabled without stopping ingestion; WTR.15 shared workflow scenario |
| Recovery | Reboot, power interruption at transaction boundaries, full/unmountable storage, failed update/validation and firmware revert; truthful last-valid-state or recovery-required outcome |

Both shipped profiles MUST pass their hardware gates. Separate artifacts permit
headless consumers to omit display costs; they do not make the control-panel
deliverable optional. A Pi 5 gateway/control panel does not itself qualify as a
bike-mounted tracker: power, enclosure, environment and radio evidence for that
role remain governed by WTR.09.

A successful cross-build proves no physical boot, Bluetooth support, durability
or GUI operation. Real hardware tests are recorded separately from local software
tests and cannot be replaced by unexecuted checklists. Firmware delivery remains
a separately authorized publication/device operation.
