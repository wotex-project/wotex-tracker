# Raspberry Pi 5 host

This separate Nerves application starts one explicit Tracker HTTP service. The
root library has no startup callback. The default headless image contains no
desktop host, Phoenix, LiveView, display server, SSH service, or active
IEx/distribution listener. Ethernet uses DHCP; NervesTime attempts NTP and
retains a last-known clock estimate under `/data`.

The source build uses `nerves_system_rpi5` 2.1.2, Nerves 1.15.0, and the target
system's OTP 29. Development builds use the local Tracker and WoTEx checkouts;
production builds require published, independently resolved packages. Install
the Nerves build tools described in the [official installation guide](https://nerves.hexdocs.pm/installation.html),
including `fwup` and SquashFS. On this repository's macOS toolchain:

```sh
WOTEX_PATH_DEPS=1 MIX_TARGET=host MIX_ENV=test mise exec -- mix deps.get
WOTEX_PATH_DEPS=1 MIX_TARGET=host MIX_ENV=test mise exec -- mix test --no-start
WOTEX_PATH_DEPS=1 MIX_TARGET=host MIX_ENV=test mise exec -- mix format --check-formatted
WOTEX_PATH_DEPS=1 MIX_TARGET=host MIX_ENV=test mise exec -- mix credo --strict
WOTEX_PATH_DEPS=1 MIX_TARGET=host MIX_ENV=test mise exec -- mix dialyzer --force-check
WOTEX_PATH_DEPS=1 MIX_TARGET=rpi5 MIX_ENV=dev \
  mise exec elixir@1.20.4-otp-29 erlang@29.0.4 -- mix deps.get
WOTEX_PATH_DEPS=1 MIX_TARGET=rpi5 MIX_ENV=dev \
  mise exec elixir@1.20.4-otp-29 erlang@29.0.4 -- mix firmware
```

The output is `_build/rpi5_dev/nerves/images/wotex_tracker_nerves.fw`. Building
does not write an SD card or validate a physical Pi. Do not use `mix burn` or
`mix upload` as a substitute for the board, EEPROM, storage and recovery gates.

## Private configuration

The appliance expects `/root/tracker/config.json` and `storage.json` in a private
0700 directory, with a separate private storage directory below it. The config
file is the shared `wtr.host.v1` JSON format documented by
[the standalone host](../app/README.md). Both files must be singly linked 0600
regular files, with no symlinked ancestors. Credentials are token hashes plus a
32-byte instance key; the firmware creates neither tokens nor a default listener
during boot. A missing storage marker stops with `recovery_required`; an invalid
configuration stops with `invalid_configuration`. Neither case silently claims
an empty history.

The firmware can additionally supervise the bounded direct-cellular listener.
This is opt-in at build time; add `WOTEX_TRACKER_CELLULAR=1` to the `deps.get`
and `firmware` commands for the selected target. The resulting image requires a
private singly linked 0600 `/root/tracker/cellular.json` in the standalone
host's closed `wtr.cellular-host.v1` format, and `config.json` must select
`teltonika.tat140.codec8e`. Missing or invalid enabled configuration fails
startup; an image built without the flag starts no cellular listener. The
cellular document chooses its numeric bind address and port. Clear TCP provides
no transport authentication or encryption, so network reachability and
firewall policy remain explicit operator responsibilities.
The build flag is closed: omit it to disable cellular ingress or set it to the
exact value `1`; any other supplied value aborts configuration instead of
silently producing a headless image without the requested listener.

Notification delivery is independently opt-in at build time. Add
`WOTEX_TRACKER_APNS=1` to the selected target's dependency and firmware commands
to require a private singly linked 0600 `/root/tracker/apns.json`. It uses the
standalone host's exact `wtr.apns-host.v1` format for the provider identity and
key, closed topics/scopes, generic copy and finite worker budgets. The appliance
loads it only from that fixed root-bound path, validates the complete service and
dispatcher composition, and supervises the dispatcher under the service. An
enabled image fails startup when the file is missing, unsafe or malformed; an
image built without the flag contains no configured dispatcher. Omit the flag or
set it to the exact value `1`; every other supplied value aborts configuration.
The flag can be combined with the independent cellular and kiosk choices.

Authenticated capabilities report `cellular` and `notification_delivery` as
`configured` only for their actually supervised appliance compositions. These
values do not establish socket reachability, provider acceptance, OS delivery,
notification presentation or a user tap. APNs still requires provisioned Apple
credentials, an entitled signed application and physical-device evidence. It
also requires the current boot to report synchronized time before the store or
dispatcher starts, because the provider adapter creates time-bound JWTs.

Only loopback and direct TLS exposure are admitted. The image has no reverse
proxy, so proxy mode is rejected. A TLS certificate and private key must each
be a singly linked 0600 regular file under `/root/tracker`. Select an explicit
HTTPS public origin. Certificate issuance, trust and renewal remain external;
the offline command below can validate and copy supplied material into the
appliance tree. The local host test exercises this configuration policy and the
service/store supervision.

Direct TLS exposure and configured notification delivery additionally require
`NervesTime.synchronized?/0` to be true in the current boot before the store or
listener starts. A last-known time file or merely plausible wall clock is not
synchronization. Failure, exception or malformed clock status stops with
`clock_unsynchronized` and leaves the prepared store untouched. A loopback
service without notification delivery deliberately does not wait for NTP, so
provisioned local tracking and the attached panel can start offline using the
explicit last-known clock estimate. That estimate is not a remote-exposure,
provider-token or hardware-RTC claim.

### Offline first provisioning

The host profile includes a create-only provisioning command for preparing a
private appliance tree before boot. Its parent directory must already exist and
the destination must be an absolute path on a filesystem that preserves Unix
ownership and modes:

```sh
WOTEX_PATH_DEPS=1 MIX_TARGET=host MIX_ENV=test mise exec -- \
  mix run --no-start scripts/provision.exs -- \
  --directory /absolute/private/staging/tracker \
  --instance-id workshop-pi --scope workshop --port 4000
```

The command uses the service package's shared host provisioner. It creates a
0700 destination and data directory, exclusive 0600 `config.json`,
`storage.json` and `operator.token` files, a fresh instance key and one operator
credential with a one-day default expiry. `storage.json` starts in `prepared`
state and carries a random non-secret storage identity. `--expires-in` accepts
1–604800 seconds. Output contains only file paths; read the token from its
private file. A repeated command refuses the occupied tree without changing it,
and failure removes only files and directories created by that attempt.

For the kiosk profile, add distinct service and browser ports:

```sh
WOTEX_PATH_DEPS=1 MIX_TARGET=host MIX_ENV=test mise exec -- \
  mix run --no-start scripts/provision.exs -- \
  --directory /absolute/private/staging/tracker \
  --instance-id workshop-pi --scope workshop \
  --port 4001 --browser-port 4000
```

`--browser-port` creates an exclusive 0600 `browser.json` with loopback-only
HTTP, a matching public origin and an independent random session-signing secret.
Its closed device-session entry binds the attached display to the supplied
service scope and exact private `operator.token`. The service and browser ports
must differ. Output contains the browser file path, never its secret or token.
The headless artifact still has no browser or UI dependency; the extra document
is used only by the explicitly selected kiosk profile.

For an explicitly network-exposed direct-TLS service, supply all four TLS
arguments together:

```sh
WOTEX_PATH_DEPS=1 MIX_TARGET=host MIX_ENV=test mise exec -- \
  mix run --no-start scripts/provision.exs -- \
  --directory /absolute/private/staging/tracker \
  --instance-id workshop-pi --scope workshop \
  --listen-ip 0.0.0.0 --public-origin https://tracker.example \
  --tls-cert /absolute/private/source/fullchain.pem \
  --tls-key /absolute/private/source/private-key.pem
```

TLS mode defaults to port 443; `--port` may override it. Both source files must
be singly linked 0600 regular files below private, symlink-free directories.
The certificate input is a bounded one-to-eight-entry PEM chain. The key must be
one supported unencrypted PEM private key and must match the leaf certificate.
Provisioning copies them to exclusive 0600 `tls-cert.pem` and `tls-key.pem`
targets, syncs and verifies the copies, and writes only those fixed runtime paths
to `config.json`. Any partial TLS argument set is rejected before creating the
tree. A later failure removes only paths made by that attempt; occupied targets
are retained. Output contains paths, never certificate or key contents.

This stages operator-supplied material; it does not issue a certificate, decide
which CA to trust, prove the public hostname, renew or rotate a certificate, or
weaken the synchronized-clock startup gate. Authenticated on-device setup also
remains separate.

The generated configuration always names `/root/tracker/config.json` and
`/root/tracker/data` as runtime paths. If `--directory` is a staging or mounted-
media path, install its contents at exactly `/root/tracker` while preserving
0700/0600 modes and ownership. That installation step is operator- and media-
specific; the command does not flash a device. Loopback remains the default;
only the complete explicit TLS argument set writes a network-exposed
configuration. The command does not issue or renew TLS material, rotate an
existing credential or provide an authenticated on-device setup screen. Browser
configuration is generated only when `--browser-port` is explicit. Those
remaining operations stay separate gates.

## Native operational resources

The host supervises a Linux procfs sampler beside the HTTP service. At startup
and every 30 seconds it reads only `/proc/meminfo`, `/proc/self/status` and
`/proc/loadavg`, admitting at most 65,536 bytes from each. One complete sample
adds system available-memory bytes, the BEAM OS-process RSS bytes and one-minute
load multiplied by 1,000 to the service's bounded volatile operational history.
It carries only the fixed `nerves` surface and `linux_procfs` source labels.
Missing or malformed fields produce no partial or invented sample. No procfs
path, process ID, device identity, credential or scope becomes telemetry.

## Storage recovery state

The service may create `data/tracker.db` only while the private marker is in its
one-time `prepared` state. After SQLite has opened, migrated its supported schema
and passed `quick_check`, startup atomically replaces that state with
`initialized`. Every later boot requires the same instance identity, data path,
private non-empty database and an intact marker. If a power interruption leaves
both marker generations, startup completes the transition only when the private
documents match exactly apart from `prepared` → `initialized` and the database
is present. A missing/empty/unsafe database, malformed or mismatched transition,
SQLite corruption, storage failure or newer unsupported schema stops startup
with `recovery_required`. It never deletes, renames or recreates that database
during recovery admission.

Recovery is operator-controlled: preserve the failed media, restore the complete
private Tracker tree from a SQLite-consistent backup onto separate media, retain
the 0700/0600 modes and storage identity, and boot the restored copy. Do not copy
a live database without its SQLite backup operation, remove the marker to force
initialization, or reuse an empty `prepared` marker for an initialized appliance.

Before installing that candidate, validate its read-only staged tree:

```sh
WOTEX_PATH_DEPS=1 MIX_TARGET=host MIX_ENV=test mise exec -- \
  mix run --no-start scripts/validate_recovery.exs -- \
  --directory /absolute/private/restored/tracker
```

The validator requires the initialized marker to match the service instance and
fixed `/root/tracker/data` path. It rejects an interrupted marker generation,
missing or non-private database, SQLite sidecars, corruption and a schema newer
or older than this image's exact current schema. Direct-TLS material is checked
at its staged equivalent path. SQLite is opened read-only for `application_id`,
`user_version`, the current table contract and `quick_check`; successful output
contains paths and validation facts only. It does not copy, migrate, rename,
delete or repair the candidate.

The source tests cover missing, corrupt, unsafe, unsupported and interrupted
states; physical power-loss, full-media, unmountable-partition and restore trials
remain required.

## Firmware validation health

Both Pi profiles enable the pinned Nerves Runtime startup guard. The release runs
Erlang heart with `HEART_INIT_TIMEOUT=600`, requiring the guard's initialization
handshake within ten minutes. After the guard registers, its pinned runtime
callback fails at 15 minutes if application startup and firmware validation do
not complete. Tracker reports its OTP application as started only after one
synchronous health check confirms all of the following:

- the initialized private storage marker still matches the service instance and
  runtime data path;
- the supervised service listener reports an actual bound address and port; and
- the live store completes its rolled-back write probe and reports this image's
  exact current schema.

The health check does not retry. An exception, exit, missing child, malformed
result or failed criterion becomes `firmware_health_failed`, stops the Tracker
supervisor and withholds the application started state. Nerves Runtime waits for
all expected applications before validating pending firmware, so a boot that has
only reached BEAM or the kiosk cannot be accepted while core storage or service
health is broken.

This source policy and the virtual boot lane do not exercise a Pi firmware-slot
transition or prove revert timing. Product acceptance still requires an actual
update, a deliberately unhealthy candidate, interrupted update/restart and proof
that the expected old image and data generation returned.

## Current limits

The development cross-build is software evidence only. No Pi 5, display,
touch controller, Bluetooth controller, SD recovery trial or firmware update
trial has been exercised. The default Nerves data-partition initialization can
reformat unreadable storage; losing the provisioned marker then fails closed but
does not recover history. Durable product acceptance still needs the physical
recovery matrix and a proven backup/restore path. The startup clock gate covers
direct TLS exposure only; long-duration drift, NTP-server selection and an
optional hardware RTC still need deployment and physical acceptance. Local
credential creation and all physical hardware gates remain open.

The build record in `../../verification/nerves-headless-build.json` contains
the local firmware digest and resolved target components when generated. The
firmware itself is deliberately untracked.

## Optional local control panel

Set `WOTEX_TRACKER_UI=1` to select a separately locked kiosk build. It uses
`kiosk_system_rpi5` 2.1.2, the shared Tracker LiveView package, a loopback
endpoint and Cog on the attached display. Myelin supplies a touch keyboard for
text fields. The kiosk launcher waits for a DRM card and gives display startup
a finite retry budget. It is a sibling of the HTTP service, so the service and
store continue when presentation is stopped. There is no SSH or distribution
listener in this profile either.

```sh
WOTEX_PATH_DEPS=1 WOTEX_TRACKER_UI=1 MIX_TARGET=host MIX_ENV=test \
  mise exec -- mix deps.get
WOTEX_PATH_DEPS=1 WOTEX_TRACKER_UI=1 MIX_TARGET=host MIX_ENV=test \
  mise exec -- mix test --no-start
WOTEX_PATH_DEPS=1 WOTEX_TRACKER_UI=1 MIX_TARGET=rpi5 MIX_ENV=dev \
  mise exec elixir@1.20.4-otp-29 erlang@29.0.4 -- mix deps.get
WOTEX_PATH_DEPS=1 WOTEX_TRACKER_UI=1 MIX_TARGET=rpi5 MIX_ENV=dev \
  mise exec elixir@1.20.4-otp-29 erlang@29.0.4 -- mix firmware
```

The firmware is `_build/ui/rpi5_dev/nerves/images/wotex_tracker_nerves.fw`.
Its dependency lock is `mix.ui.lock`, separate from the headless `mix.lock`.

The kiosk also needs `/root/tracker/browser.json`, a private 0600 file under
the same private directory as the service configuration. Prefer the optional
offline provisioning flag above. The closed document is:

```json
{
  "schema": "wtr.browser.v2",
  "listen": {"ip": "127.0.0.1", "port": 4000},
  "exposure": "loopback",
  "public_origin": "http://127.0.0.1:4000",
  "secret_key_base": "replace-with-at-least-64-unpredictable-characters",
  "device_session": {"scope": "workshop"}
}
```

The signing secret must be independently generated and kept private. Version two
also requires the fixed private `operator.token` to match a credential granting
read access in the named scope. At display launch the host authenticates that
credential into the bounded server-held session store, passes Cog only a random
60-second nonce, and accepts that nonce once from loopback. The exchange renews
the encrypted HTTP-only cookie and redirects directly to `/setup`; neither the
bearer nor opaque session identifier enters the URL or rendered page. Exchange
reauthorizes through the service, so expiry and revocation still deny the panel.
Manual sign-in remains available after sign-out or a failed bootstrap, and a
device without the private provisioned files still cannot reach an authenticated
panel.

The host test executes the HTTP exchange, authenticated setup render, replay
denial and controlled presentation restart while retaining the store. This is
software evidence for authenticated attached-display setup, not on-device
credential creation or physical display evidence. GPU, touch, keyboard,
orientation, offline workflow and physical fault isolation remain hardware
acceptance work, not conclusions from the cross-build.

`../../verification/nerves-kiosk-build.json` records the resolved kiosk
artifact when generated. Raspberry Pi OS containers can exercise ARM64 userland
but cannot boot this Nerves firmware or validate its board/display path; the
[Nerves ARM64 QEMU system](https://github.com/nerves-project/nerves_system_qemu_aarch64)
is the closer virtual boot candidate.

## Virtual ARM64 boot lane

`MIX_TARGET=qemu_aarch64` builds a separate headless software-test image with
`nerves_system_qemu_aarch64` 0.4.2 and `mix.qemu.lock`. It is not a Pi artifact.
This profile alone creates an unpredictable, inaccessible test credential on its
first boot under the private `/root/tracker` mount together with the same prepared
storage marker. The private credential is retained only on the virtual disk for
the probe and never enters runtime configuration or serial output. Successful
SQLite startup advances the marker before the probe. The listener remains guest
loopback-only. The probe submits one deterministic Ruuvi RAWv2 observation over
the authenticated HTTP interface with a fixed idempotency key, requires the
decoded public state to report 24.3 °C, and receives the same durable operation
replay after reboot. It also checks the private SQLite file, `/health/live` and
one native resource sample, reporting only pass or fail to the serial console.
The Pi profiles never compile this fixture or turn on a serial logger.

```sh
WOTEX_PATH_DEPS=1 MIX_TARGET=qemu_aarch64 MIX_ENV=dev \
  mise exec elixir@1.20.4-otp-29 erlang@29.0.4 -- mix deps.get
WOTEX_PATH_DEPS=1 MIX_TARGET=qemu_aarch64 MIX_ENV=dev \
  mise exec elixir@1.20.4-otp-29 erlang@29.0.4 -- mix firmware
WOTEX_PATH_DEPS=1 MIX_TARGET=qemu_aarch64 MIX_ENV=dev \
  mise exec elixir@1.20.4-otp-29 erlang@29.0.4 -- mix nerves.gen.qemu
```

The last task creates the ignored `virtual-disk.img` and prints a QEMU command
for the current host. Run it, wait for the probe to report the private store,
loopback HTTP, authenticated fixture ingress and native resources, stop QEMU,
and run the same command again without regenerating the disk. The second boot
must pass without formatting the application partition and must replay rather
than recommit the fixture operation. `record_qemu_boot.exs`
verifies both serial logs and writes
`../../verification/nerves-qemu-boot.json`. On this macOS host, QEMU 11.1.1
uses Hypervisor Framework acceleration. The Nerves virtual system is new and
does not replace Pi 5 board, display, radio, power or storage-failure tests.
