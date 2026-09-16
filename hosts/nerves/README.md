# Headless Raspberry Pi 5 host

This is a separate Nerves application that starts one explicit Tracker HTTP
service. The root library has no startup callback. This image does not contain
the desktop host, Phoenix, LiveView, a display server, SSH service, or an active
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

The appliance expects `/data/tracker/config.json` in a private 0700 directory,
with a separate private storage directory below it. The file is the shared
`wtr.host.v1` JSON format documented by [the standalone host](../app/README.md).
It must be a singly linked 0600 regular file, with no symlinked ancestors.
Credentials are token hashes plus a 32-byte instance key; the firmware creates
neither tokens nor a default listener. A missing or invalid document stops the
Tracker application with a fixed `invalid_configuration` error. It does not
silently claim an empty history.

Only loopback and direct TLS exposure are admitted. The image has no reverse
proxy, so proxy mode is rejected. A TLS certificate and private key must each
be a singly linked 0600 regular file under `/data/tracker`. Select an explicit
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
clock needs a device policy before exposed use. The separate UI-enabled image,
local authenticated setup, presentation failure isolation and hardware gates
remain open.

The build record in `../../verification/nerves-headless-build.json` contains
the local firmware digest and resolved target components when generated. The
firmware itself is deliberately untracked.
