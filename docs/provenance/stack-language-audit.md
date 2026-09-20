# WoTEx implementation language audit

The WoTEx repositories use Elixir/OTP for libraries, services, tests and
orchestration. New bounded native helpers and independent consumers use Zig;
platform framework lifecycle remains in its safe native language. Existing C,
C++ and Rust surfaces are compatibility or migration inputs. A repository-owned Python runtime, client, test
runner or build harness is migration debt. A pinned upstream SDK generator that
requires Python at build time is a narrower exception; it does not justify
shipping an interpreter or writing our own orchestration in Python.

Follow-up, 2026-09-20: a read-only inspection of committed monorepo source at
[`1793303ffcdfd92e325856b2f44562448046f76a`](https://github.com/wotex-project/wotex/tree/1793303ffcdfd92e325856b2f44562448046f76a/packages/wotex-ble)
finds no first-party Python source or requirements manifest under
`packages/wotex-ble`. The native persistent backend and C++ software peer close
the BLE migration item in the historical table below. This focused follow-up did
not rerun the complete 17-repository inventory or establish Tracker passive
scanning or hardware acceptance.

## Scope and result

The 2026-09-16 rescan inspected 2,695 tracked and unignored files across all 17
top-level `wotex*` Git checkouts. It read source, specs, plans, repository
instructions, package lists, Mix gates, shell scripts, containers and dependency
manifests. All 17 worktrees were clean at the scan. Counts below cover 32 Python
source files and two requirements manifests; invocation sites are additional
findings, not extra Python source files. No additional untracked Python surface
was found. Ignored dependencies, build products and disposable upstream SDK
copies are excluded from first-party counts. Their declared use is included in
the build-tool findings. This is a source audit, not a fresh execution of every
sibling's native acceptance suite.

The Tracker CLI consumer originally used Python's standard library for process
launch, JSON, temporary files and assertions. None of those operations
required Python. It was a convenience choice, not a protocol, platform or SDK
requirement. Elixir/OTP supplies the same facilities; the independent Zig wire
consumer supplies an additional native client. Using a second language alone
never established client independence. The functions of the sibling scripts are
observable below; their original authors' motivations are not inferred.

| Repository | Tracked Python surfaces | Why they are present | Required correction |
| --- | ---: | --- | --- |
| `wotex-tracker` | 0 after this migration | The earlier CLI, OpenAPI consumer, signed registry, archive and release probes used Python as a convenient OS-process/HTTP tool. No protocol or upstream SDK required it. | Elixir/OTP now owns all of these paths. The full gate rejects a regression. |
| `wotex-ble` | 21 | `priv/bluez/*.py` and its requirements provide the existing persistent `dbus-next` BlueZ owner. `test/native/*.py`, `test/interop/*.py` and `test/support/bluez_process.py` provide bridge contracts and virtual-controller peers; `.check.exs`, fixture wrappers and a Dockerfile invoke them. The C++17/libdbus Port is the accepted native target, but the public software-peer and stress matrix remains incomplete. | Complete the native Port's public BEAM/Runtime qualification, select it instead of the Python bridge, remove the bridge and its requirement manifest, and move repository test orchestration/assertions to ExUnit and C++ fixtures. A genuinely independent GATT peer can remain in another language only with an explicit, bounded fixture exception and no production IPC dependency. |
| `wotex-coap` | 0 | The former `test/interop/libcoap/run.py` runner has been removed. `docs/provenance/software-udp-dtls-v1.json` records an actual historical run of that runner. | No active Python violation found. Preserve that receipt's original identity; it is not a current execution instruction. |
| `wotex-matter` | 2 | `priv/matter_bridge.py` and its bridge test implement an optional legacy factory adapter to the upstream connectedhomeip Python controller API. The accepted first-party persistent C++17 controller Port has substantial read/write/subscription/commissioning coverage. Native SDK builds invoke upstream Python generation and fetch pinned Python build dependencies. The software execution container also installs `python3`. | Remove the optional adapter and test after native API parity is confirmed. Remove the execution-container interpreter unless a specific remaining test actually requires it. Keep only the minimum pinned Python tools that the upstream connectedhomeip build actually requires, with no interpreter in the release or client path. |
| `wotex-opcua` | 3 | `priv/opcua_bridge.py`, `priv/requirements.txt` and `test/interop/secure_peer.py` support the current per-request asyncua adapter and independent secure peer. The accepted open62541 C Port has a build/bootstrap and value-codec foundation but no native Session yet. open62541's upstream generator needs Python during the native build. | Finish native Session/security/subscription behavior, remove the runtime asyncua bridge and requirements, and replace or explicitly isolate the independent test peer. Keep only the upstream generator as a pinned build prerequisite. |
| `wotex-thread` | 8 | `priv/openthread/build.py` and six `test/native/*.py` files build and probe the C++17 OpenThread host; `test/fixtures/sdk_bridge.py`, `test/native/run_owner.sh` and ExUnit wrappers launch Python fixtures. Production already uses a native Port. | Move build orchestration to Mix and assertions to ExUnit/C++; replace the fixture bridge and shell runner. Any upstream OpenThread generator remains a build-only dependency if the pinned SDK requires it. |

The other inspected repositories had no tracked `.py` or Python requirements
manifest: `wotex`, `wotex-bacnet`, `wotex-binding-http`, `wotex-binding-mqtt`,
`wotex-conformance`, `wotex-continuum`, `wotex-directory`, `wotex-lab`,
`wotex-modbus`, `wotex-nx` and `wotex-runtime`. Modbus's old Python receipt and
Lab's migration notes are historical evidence, not active dependencies. There
are 34 tracked Python files/manifests in the four sibling repositories that
still contain them. A
zero-file count does not by itself prove a clean toolchain: Matter and OPC UA
invoke upstream Python inside native SDK builds, while BLE and Thread also
invoke Python from Mix, shell or container configuration.

The Tracker gate checks tracked and new unignored files, including executable
and build surfaces, Erlang, CMake, JavaScript/TypeScript, package scripts and
extensionless shebang scripts. It rejects Python source, notebooks, packaged
artifacts, manifests and interpreter/package-tool invocations. Historical
specifications and this audit keep the word “Python” when it describes a real
legacy boundary or an upstream prerequisite;
those descriptions are not executable dependencies.

The separate-process Elixir HTTP client preserves wire/OpenAPI independence
from service domain code. An independent Zig client now also exercises the
implemented observation, enrollment, materialisation, Property, history,
operation-receipt, analytics query and paging, saved query lifecycle, SSE-resume,
API version and idempotency rejection, and active-stream revocation flow against
both bundled releases.
Full cross-language product acceptance still requires the remaining policies and
authorized interactions as those surfaces are implemented. Neither client adds
a scripting runtime to the release or verification image.

## Invocation, packaging and specification findings

### BLE

- `lib/wotex/ble/bluez/connection.ex:464` launches the packaged legacy bridge.
  `mix.exs:120` includes its five Python modules and requirements;
  `bin/check_archive.exs:12` requires them in the archive. Migrating only the
  caller or deleting one script would leave an inconsistent package contract.
- `.check.exs:12` runs Python unittest. `test/support/native_fixture.ex:16` and
  `test/wotex/ble/stream_bridge_test.exs:15` generate Python launcher scripts.
  These are first-party tests and process fixtures; they can use ExUnit and C++.
- `test/interop/virtual/Dockerfile:4` installs the interpreter, creates a virtual
  environment and runs a Python manifest writer. The VM/public runners and
  `virtual/guest.sh`/`virtual/public.sh` launch the Python peers. Separate peer
  execution from generic VM, manifest, build and cleanup orchestration.
- `WBL.13-native-backend.md:41` already assigns generic orchestration to
  Mix/ExUnit. Its explicit exception at line 654 permits the independent GATT
  server to export objects to real BlueZ and observe Confirm calls; it cannot
  supply native-client IPC responses. That is a bounded interoperability
  rationale, not permission for the Python production bridge or VM runner.
  Preserve the independent wire test when replacing that peer with Zig or a
  separately justified SDK-native peer.
- The implemented-profile and catalogue descriptions accurately identify the
  legacy backend. Update them when native parity is evidenced, without claiming
  that the native target already satisfies the full software/stress matrix.

### Matter

- `lib/wotex/matter/sdk.ex:101` invokes the one-shot Python factory bridge.
  `mix.exs:122` packages the bridge and Python test; the software source manifest
  also lists the bridge. `WMA.03-sdk-client.md` specifies this legacy API.
  Native profiles in `WMA.12` and `WMA.13` already forbid falling back to it.
  Removing it requires updating the legacy API, tests, archive list and manifest.
- `bin/check_p03_native.exs` and `test/support/software/build.exs` install eight
  pinned Python build artifacts from `test/support/software/sources.json`.
  The connectedhomeip SDK's `build/chip/chip_codegen.gni` calls
  `scripts/codegen.py`, `scripts/codegen_paths.py` and
  `scripts/tools/zap/generate.py`. These upstream generation steps are the
  strongest concrete reason to retain an isolated build-time interpreter.
  They do not justify the legacy factory adapter.
- `test/support/software/run.exs:173` separately installs `python3` in the
  software execution container. No Python invocation appears in that runner.
  This does not prove production uses Python, but it prevents the test image
  from demonstrating execution without an installed interpreter. Remove the
  install and rerun the lane, or identify and migrate the exact legacy test
  still requiring it. The SDK builder and execution container are distinct.

### OPC UA

- `lib/wotex/opcua/asyncua.ex:93` invokes the current per-request Python bridge;
  `mix.exs:121` packages it and `priv/requirements.txt`. The native open62541
  foundation does not yet activate a successful Session. Deleting the bridge
  now would remove the existing network implementation. Complete Session,
  security, services and subscriptions before switching the public adapter.
- `test/interop/secure_peer.py` uses asyncua as the secure server. The current
  client also uses asyncua, so that pair is same-stack evidence. Against a
  completed open62541 client, asyncua supplies a genuinely different protocol
  implementation. That is the bounded peer rationale in `WOP.10` and `WOP.13`;
  a different native peer can replace it if equivalent independent coverage is
  retained. The specified C precision peer remains necessary for exact 100 ns
  timestamps that asyncua's Python datetime cannot represent.
- `lib/wotex/opcua/native/toolchain.ex` locates Python and `native/recipe.ex:139`
  passes `Python3_EXECUTABLE` to open62541's build. This declared upstream
  generator dependency belongs only in the build environment. It is separate
  from asyncua and does not justify shipping `priv/requirements.txt`.
- The target specs already exclude runtime Python. Move any retained independent
  fixture requirements under `test/interop`, as the provenance contract requires,
  and update the implemented profile only after native network tests pass.

### Thread

- `priv/openthread/build.py` owns SDK download/patch/build orchestration;
  `lib/wotex/thread/open_thread.ex:5` and `priv/openthread/CMakeLists.txt:45`
  direct users to it. Migrate those operations and instructions to the specified
  Mix build task. Preserve the two audited SDK patches and source checks.
- Six `test/native/*_test.py` files and `test/native/run_owner.sh` implement
  process, dataset, commissioning, formation and management assertions. The
  shell runner also embeds Python for result metadata. Replace orchestration
  and assertions with ExUnit/C++, including its generated child-process fixtures.
- `test/wotex/thread/sdk_bridge_test.exs` copies and launches
  `test/fixtures/sdk_bridge.py`. This is an injected process fixture, not an
  independent upstream Thread stack; there is no interoperability reason to
  retain Python here.
- `WTH.13-native-backend.md:250` already calls these utilities a baseline and
  assigns their replacement to Mix/ExUnit. Its actual RCP/FTD software peer is
  compiled upstream code. No specific additional upstream Python dependency is
  asserted by this audit; one must be identified before claiming an exception.

### Enforcement

The sibling CLAUDE contracts and native target specs already restrict Python to
upstream tools or explicitly justified peers. The remaining runtime adapters and
generic runners do not satisfy those targets. Their local gates still need
equivalent language enforcement after migration. A blanket peer exception would
reintroduce the problem: identify the peer, independent stack, required behavior,
dependency pins and reason a native alternative cannot yet replace it.

Tracker's `AGENTS.md`, implementation spec, plan and executable gate enforce its
stricter zero-Python rule. The independent consumer is Zig; host orchestration
and CLI acceptance are Elixir. Tracker has no upstream build exception. The
local commit rule also lives in `AGENTS.md`: conventional prefix, natural
description and no specification/work-package identifier. The 62 unpushed commit
subjects at the scan contained no specification identifiers.

## Complete remaining file inventory

Paths are relative to their named repository. These are all 34 files/manifests;
the non-Python callers and specification debt are listed above.

### wotex-ble — 21

```text
priv/bluez/bridge.py
priv/bluez/client.py
priv/bluez/notifications.py
priv/bluez/pairing.py
priv/bluez/procedures.py
priv/bluez/requirements.txt
test/interop/public_machine.py
test/interop/virtual/build_manifest.py
test/interop/virtual/dbus_monitor.py
test/interop/virtual/gatt_peer.py
test/interop/virtual/native_gatt.py
test/interop/virtual/public_peer.py
test/interop/virtual_machine.py
test/native/dbus_live.py
test/native/test_agent.py
test/native/test_bluez.py
test/native/test_notifications.py
test/native/test_procedures.py
test/native/test_public_machine.py
test/native/test_virtual_machine.py
test/support/bluez_process.py
```

### wotex-matter — 2

```text
priv/matter_bridge.py
test/bridge/matter_bridge_test.py
```

### wotex-opcua — 3

```text
priv/opcua_bridge.py
priv/requirements.txt
test/interop/secure_peer.py
```

### wotex-thread — 8

```text
priv/openthread/build.py
test/fixtures/sdk_bridge.py
test/native/build_test.py
test/native/commissioner_test.py
test/native/dataset_test.py
test/native/formation_test.py
test/native/management_test.py
test/native/owner_test.py
```

## Source snapshot

The sibling checkouts were inspected read-only because another session is
implementing their native targets. These revisions identify this audit; they
are not dependency pins or claims about subsequent work.

A follow-up scan at Tracker `64e08a1`, including its uncommitted shared UI work,
found the same sibling revisions and the same 34-file inventory. It also
reviewed interpreter, package-tool and bridge references across source,
configuration and specifications. No new Tracker Python surface was present.
The original clean-worktree statement above describes the earlier snapshot;
the follow-up included ongoing Tracker changes.

```text
wotex                 eadc6c9
wotex-bacnet          966373b
wotex-binding-http    c150da6
wotex-binding-mqtt    16dddd8
wotex-ble             993c368
wotex-coap            657a4d0
wotex-conformance     d11751a
wotex-continuum       81e5f7f
wotex-directory       960c1cd
wotex-lab             73161df
wotex-matter          13600e4
wotex-modbus          bcd57ba
wotex-nx              8993010
wotex-opcua           2ccc6d9
wotex-runtime         65d0b52
wotex-thread          fd0cad3
wotex-tracker         4e0f5ee
```
