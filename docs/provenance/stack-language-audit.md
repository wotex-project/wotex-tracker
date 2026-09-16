# WoTEx implementation language audit

The WoTEx repositories use Elixir/OTP for libraries, services, tests and
orchestration. Native protocol boundaries use the language of their SDK or
platform, usually C or C++17. A repository-owned Python runtime, client, test
runner or build harness is migration debt. A pinned upstream SDK generator that
requires Python at build time is a narrower exception; it does not justify
shipping an interpreter or writing our own orchestration in Python.

This audit inspected tracked source and active build/test references in the
`wotex*` sibling checkouts on 2026-09-16. Counts include `.py` files and Python
`requirements*.txt` manifests. They exclude ignored build products and upstream
source downloaded into temporary workspaces. The sibling repositories are being
developed independently; their exact worktree state may change after this scan.

| Repository | Tracked Python surfaces | Why they are present | Required correction |
| --- | ---: | --- | --- |
| `wotex-tracker` | 0 after this migration | The earlier CLI, OpenAPI consumer, signed registry, archive and release probes used Python as a convenient OS-process/HTTP tool. No protocol or upstream SDK required it. | Elixir/OTP now owns all of these paths. The full gate rejects a regression. |
| `wotex-ble` | 21 | `priv/bluez/*.py` and its requirements provide the existing persistent `dbus-next` BlueZ owner. `test/native/*.py`, `test/interop/*.py` and `test/support/bluez_process.py` provide bridge contracts and virtual-controller peers; `.check.exs`, fixture wrappers and a Dockerfile invoke them. The C++17/libdbus Port is the accepted native target, but the public software-peer and stress matrix remains incomplete. | Complete the native Port's public BEAM/Runtime qualification, select it instead of the Python bridge, remove the bridge and its requirement manifest, and move repository test orchestration/assertions to ExUnit and C++ fixtures. A genuinely independent GATT peer can remain in another language only with an explicit, bounded fixture exception and no production IPC dependency. |
| `wotex-coap` | 1 | `test/interop/libcoap/run.py` is a leftover test runner. Current Mix/ExUnit software build/run tasks already own the native libcoap workflow. | Remove the superseded runner and use the Mix/ExUnit entry points. No runtime reason remains. |
| `wotex-matter` | 2 | `priv/matter_bridge.py` and its bridge test implement an optional legacy factory adapter to the upstream connectedhomeip Python controller API. The accepted first-party persistent C++17 controller Port has substantial read/write/subscription/commissioning coverage. Native SDK builds invoke upstream Python generation and fetch pinned Python build dependencies. | Remove the optional adapter and test after native API parity is confirmed. Keep only the minimum pinned Python tools that the upstream connectedhomeip build actually requires, with no interpreter in the release or client path. |
| `wotex-opcua` | 3 | `priv/opcua_bridge.py`, `priv/requirements.txt` and `test/interop/secure_peer.py` support the current per-request asyncua adapter and independent secure peer. The accepted open62541 C Port has a build/bootstrap and value-codec foundation but no native Session yet. open62541's upstream generator needs Python during the native build. | Finish native Session/security/subscription behavior, remove the runtime asyncua bridge and requirements, and replace or explicitly isolate the independent test peer. Keep only the upstream generator as a pinned build prerequisite. |
| `wotex-thread` | 8 | `priv/openthread/build.py` and six `test/native/*.py` files build and probe the C++17 OpenThread host; `test/fixtures/sdk_bridge.py`, `test/native/run_owner.sh` and ExUnit wrappers launch Python fixtures. Production already uses a native Port. | Move build orchestration to Mix and assertions to ExUnit/C++; replace the fixture bridge and shell runner. Any upstream OpenThread generator remains a build-only dependency if the pinned SDK requires it. |

The other inspected repositories had no tracked `.py` or Python requirements
manifest: `wotex`, `wotex-bacnet`, `wotex-binding-http`, `wotex-binding-mqtt`,
`wotex-conformance`, `wotex-continuum`, `wotex-directory`, `wotex-lab`,
`wotex-modbus`, `wotex-nx` and `wotex-runtime`. There are 35 tracked Python
files/manifests in the five sibling repositories above. A zero-file count does
not by itself prove a clean toolchain: Matter and OPC UA invoke upstream Python
inside native SDK builds, while BLE and Thread also invoke Python from Mix,
shell or container configuration.

The tracker gate checks tracked and new unignored files, including executable
and build surfaces. Historical specifications and this audit keep the word
“Python” when it describes a real legacy boundary or an upstream prerequisite;
those descriptions are not executable dependencies.

The separate-process Elixir HTTP client preserves wire/OpenAPI independence
from service domain code. An independent Rust client now also exercises the
implemented observation, enrollment, materialisation, Property, history,
operation-receipt, analytics query, SSE-resume, API version and idempotency
rejection, and active-stream revocation flow against both bundled releases.
Full cross-language product acceptance still requires the remaining policies and
authorized interactions as those surfaces are implemented. Neither client adds
a scripting runtime to the release or verification image.
