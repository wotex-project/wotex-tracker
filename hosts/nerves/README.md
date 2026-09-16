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
WOTEX_PATH_DEPS=1 MIX_TARGET=rpi5 MIX_ENV=dev \
  mise exec elixir@1.20.4-otp-29 erlang@29.0.4 -- mix deps.get
WOTEX_PATH_DEPS=1 MIX_TARGET=rpi5 MIX_ENV=dev \
  mise exec elixir@1.20.4-otp-29 erlang@29.0.4 -- mix firmware
```

The output is `_build/rpi5_dev/nerves/images/wotex_tracker_nerves.fw`. Building
does not write an SD card or validate a physical Pi. Do not use `mix burn` or
`mix upload` as a substitute for the board, EEPROM, storage and recovery gates.

## Private configuration

The appliance expects `/root/tracker/config.json` in a private 0700 directory,
with a separate private storage directory below it. The file is the shared
`wtr.host.v1` JSON format documented by [the standalone host](../app/README.md).
It must be a singly linked 0600 regular file, with no symlinked ancestors.
Credentials are token hashes plus a 32-byte instance key; the firmware creates
neither tokens nor a default listener. A missing or invalid document stops the
Tracker application with a fixed `invalid_configuration` error. It does not
silently claim an empty history.

Only loopback and direct TLS exposure are admitted. The image has no reverse
proxy, so proxy mode is rejected. A TLS certificate and private key must each
be a singly linked 0600 regular file under `/root/tracker`. Select an explicit
HTTPS public origin and provision certificates and operator tokens outside the
firmware. The local host test exercises this configuration policy and the
service/store supervision, but there is not yet a device provisioning workflow.

## Current limits

The development cross-build is software evidence only. No Pi 5, display,
touch controller, Bluetooth controller, SD recovery trial or firmware update
trial has been exercised. The default Nerves data-partition initialization can
reformat unreadable storage; a durable product image needs a tested recovery
policy before history preservation can be claimed. Offline clock estimates are
not trusted NTP synchronization, so credential expiry under an unsynchronized
clock needs a device policy before exposed use. Local authenticated bootstrap
setup and hardware gates remain open.

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
the same private directory as the service configuration:

```json
{
  "schema": "wtr.browser.v1",
  "listen": {"ip": "127.0.0.1", "port": 4000},
  "exposure": "loopback",
  "public_origin": "http://127.0.0.1:4000",
  "secret_key_base": "replace-with-at-least-64-unpredictable-characters"
}
```

The signing secret must be independently generated and kept private. The
browser signs in with a provisioned service token. The present image has no
on-device credential/bootstrap setup, so a device without these files cannot
reach an authenticated panel. The host test verifies the loopback page and
that a controlled presentation restart retains the store. GPU, touch, keyboard,
orientation, offline workflow and physical fault isolation remain hardware
acceptance work, not conclusions from the cross-build.

`../../verification/nerves-kiosk-build.json` records the resolved kiosk
artifact when generated. Raspberry Pi OS containers can exercise ARM64 userland
but cannot boot this Nerves firmware or validate its board/display path; the
[Nerves ARM64 QEMU system](https://github.com/nerves-project/nerves_system_qemu_aarch64)
is the closer virtual boot candidate.
