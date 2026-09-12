# WTR.14 Optional Nerves firmware and LiveView hosts

## Status

Accepted target contract. No host, firmware image, UI or Pi hardware acceptance
exists yet. These are consumers of the pure library, not additions to its startup
or dependency contract. WTR.13 continues to govern the root package.

## Separate library and appliance

`wotex_tracker` remains a normal Mix library with no application startup callback.
`hosts/nerves/` is a separate firmware Mix application. It owns its callback,
supervisor, board configuration, network interfaces, time synchronization,
persistent data, credentials and explicitly configured Tracker service instances.
Its dependency direction is host -> Tracker -> core WoTEx values. Nothing in core
imports the host. The root archive excludes hosts and their locks/build assets.

`hosts/workbench/` may provide a desktop/server application with the same public
service and optional UI. Firmware must not start that application's whole tree.
If both hosts need shared web code, extract inert LiveView/HEEx/router/endpoint
modules with explicit child specs; keep application callbacks and deployment
configuration in each host. No cross-host framework is needed for the first boot.

The boot application may start its declared services automatically at boot; the
library never starts them merely because it is installed. Multiple Tracker
instances still take independent values/ports. A host's intentionally global
OS/network management does not become global Tracker configuration.

## Raspberry Pi 5 target

The candidate baseline is `nerves_system_rpi5` 2.1.2, Nerves 1.15.0 and
`MIX_TARGET=rpi5`, observed 2026-09-12. Exact firmware resolution and target OTP
must be recorded from the built artifact; desktop Mix constraints do not select
the embedded runtime. The system is a 64-bit Pi 5 target with Ethernet/Wi-Fi,
but its documentation marks Bluetooth **untested**. Older boards can need an
EEPROM update; the 2.x system requires firmware validation for updates to persist
across reboot. These are upstream facts, not Tracker hardware qualification.
[Pi 5 system documentation](https://nerves-system-rpi5.hexdocs.pm/readme.html),
[exact system release](https://hex.pm/api/packages/nerves_system_rpi5/releases/2.1.2).

Begin with a headless image and admitted fixture or network/software-peer input.
Do not make onboard BLE a prerequisite for boot proof. A later BLE lane must
name the controller, firmware, bus, permissions and backend; qualify ownership,
scan bytes, reconnect and cleanup on that exact Nerves system. Reusing a desktop
BlueZ build or assuming BlueHeron support from another Pi is insufficient.
Generic BLE changes belong with `wotex_ble`, with its own native target rules.

The host uses Nerves networking/time libraries only as host dependencies. Offline
boot must expose unsynchronized time honestly and retain the explicit receiver
time/monotonic deadline distinction. Firmware/device serial numbers are private
host identifiers, not public Thing IDs. Cloud management and NervesHub are
optional; boot, local ingestion and local inspection must work without them.

## Optional UI

The reference UI uses Phoenix LiveView, HEEx and Phoenix components. No separate
SPA runtime is required. Minimal JavaScript hooks may support browser-specific
features such as a map, but do not own identity, evidence, policy or canonical
state. Streams and history requests are bounded; socket assigns are projections.

Ship separate tested headless and UI-enabled build profiles. A headless artifact
contains no Phoenix/LiveView dependency or web endpoint. A UI-enabled host only
starts its endpoint when explicitly configured. Enabling/disabling the endpoint
must not reset ingestion or rewrite identity. The UI serves a browser on another
device by default; a local HDMI kiosk/browser is not part of this contract.

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

The volatile first boot profile needs no database. A durable profile additionally
passes WTR.06 transaction/replay tests on the actual target storage. Specify data
partition capacity, full-disk behavior, write/retention limits, initialization
markers and backup/recovery procedure. Firmware rollback and application-data
rollback are separate: an older image must read the stored schema or fail with
an explicit recovery requirement. Never validate firmware solely because its UI
responds while ingestion/storage is broken.

Updates use the chosen Nerves system's firmware validation and revert mechanism
with documented health criteria and a finite startup budget. Test bad images,
failed validation, interrupted update and restart, and preserve evidence of which
image/data generation actually ran. Operator recovery procedures must identify
destructive steps; documentation is not authority to flash or erase a device.

## Acceptance matrix

| Lane | Required executable evidence |
|---|---|
| Root package | Archive consumer with no Nerves/Phoenix/LiveView/Refpath; no Tracker startup callback or implicit I/O |
| Headless firmware build | Pinned system/toolchain/dependency digests, artifact manifest, native target architecture, models included, secrets/web/private modules excluded |
| Physical headless boot | Real Pi 5 board/EEPROM/storage record; deterministic fixture result matches desktop; service supervision and local inspection; bounded startup with network/AI absent |
| Real ingress | Exact network or BLE backend; disconnect/reconnect and owner loss; observation -> TD -> Runtime proof; unsupported radio reported explicitly |
| UI-enabled firmware | Same service API/results; authenticated LiveView inspection; revoked-session/mutation tests; bounded streams; endpoint disabled without stopping ingestion |
| Recovery | Reboot, power interruption at transaction boundaries, full/unmountable storage, failed update/validation and firmware revert; truthful last-valid-state or recovery-required outcome |

A successful cross-build proves no physical boot, Bluetooth support, durability
or GUI operation. Real hardware tests are recorded separately from local software
tests and cannot be replaced by unexecuted checklists. Firmware delivery remains
a separately authorized publication/device operation.
