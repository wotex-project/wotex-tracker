# Standalone Tracker host

This optional application owns startup of the service and, when explicitly built
and configured, its browser interface. The root library and service package keep
their explicit, inert installation contract.

Startup requires `WOTEX_TRACKER_CONFIG` to name an absolute regular 0600 JSON
file in a 0700 directory. Paths must not traverse symlinks. There is no default
configuration or token. The closed `wtr.host.v1` document contains:

- `instance_id`: nonempty instance identifier;
- `secret_key`: canonical Base64 of a fresh random 32-byte instance key;
- `data_directory`: existing private absolute directory for SQLite;
- `listen`: numeric `ip` and integer `port`;
- `exposure`: `loopback`, `proxy` or `tls`;
- `public_origin`: explicit origin, or `listener` in loopback mode;
- `credentials`: 1–32 entries with `id`, `principal`, lowercase hexadecimal
  `token_sha256`, scope-to-grants map `grants`, and Unix-millisecond `expires_at`;
- optional `tls`: exact `certfile` and `keyfile` absolute paths in TLS mode;
- optional `storage_limits`: lower ceilings for `max_rows` (≤100000),
  `max_pages` (≤262144), `busy_timeout` (≤1000 ms) and `timeout` (≤5000 ms).

HTTP server exposure and grant semantics are those of `wotex_tracker_service`.
The instance key is secret; credential entries contain token hashes. The host
reads at most 64 KiB, rejects duplicate/unknown fields and fails startup with a
fixed error that contains no secret or path. The OS account is trusted.

Development uses `WOTEX_PATH_DEPS=1 MIX_ENV=test mise exec -- mix check --no-retry`.
Tests explicitly start dependencies and test host startup; the test runner does
not boot an unconfigured service. Production rejects the path-dependency switch.

## Command-line workflow

`bin/trackerctl` is a POSIX launcher for the Elixir client. Source use loads the
compiled Mix code paths; releases run it on their bundled ERTS. It uses the
authenticated HTTP API. Tokens are read from a private 0600 file; they never
belong in command arguments, URLs or environment variables. The client ignores
proxy environment variables, verifies HTTPS certificates, follows no redirects
and retries no operation.

Create a new loopback configuration (the parent directory must already exist):

```sh
bin/trackerctl --scope workshop init --directory "$PWD/_build/local" \
  --instance-id workshop --bind 127.0.0.1 --port 4000
```

This creates a 0700 directory, a private configuration and a fresh operator token
with all scope grants and a one-day expiry. `--expires-in` permits 1–604800 seconds.
Initialization refuses existing files; it never rotates credentials or replaces
data implicitly. It prints file paths, never the token. A partial filesystem
failure requires inspecting the newly created directory before trying again.

For source development, start the configured host from this directory:

```sh
WOTEX_PATH_DEPS=1 MIX_ENV=test WOTEX_TRACKER_CONFIG="$PWD/_build/local/config.json" \
  mise exec -- mix run --no-halt
```

In a second terminal, use the same explicit origin, scope and token file:

```sh
bin/trackerctl --url http://127.0.0.1:4000 --scope workshop \
  --token-file "$PWD/_build/local/operator.token" capabilities
```

With those global options before the command, the available commands are:

| Command | Purpose |
| --- | --- |
| `ready`, `capabilities` | Writable storage and explicit capability status |
| `import observation.json --generation 0` | Admit an observation envelope |
| `list observations`, `inspect observations ID` | Public inspection |
| `enroll ID --title "Sensor" --confirm --generation 1` | Confirm the operator association |
| `associate THING OBSERVATION --confirm --generation N` | Confirm a later observation for the same Thing |
| `materialize THING --generation 2` | Persist the evidence-backed TD and initial state |
| `list things`, `read THING temperature` | Inspect TDs and read Properties |
| `observe THING temperature --seconds 30 --max-events 100` | Committed Property values; resume explicitly with `--cursor` |
| `history state THING --limit 25` | Immutable history; resume with `--cursor` |
| `events --cursor CURSOR` | Bounded replay from a snapshot/event cursor |
| `events --cursor CURSOR --stream --seconds 30 --max-events 100` | Bounded SSE delivery |
| `raw observations ID --output export.json` | Original native JSON bytes to a new 0600 file |
| `operation UUID` | Resolve the retained outcome without repeating an operation |
| `revoke CREDENTIAL_ID --generation N` | Permanently revoke this scope's credential ID |

Every mutation requires the expected generation. Supply `--operation UUID` to
choose its identity, or retain the generated UUID printed to stderr before the
attempt. Output is JSON, one event per line for SSE. Exit 0 means success; 1 is
an API/client failure; 2 is argument usage; 3 means an uncertain mutation outcome
and requires `operation UUID` lookup. A preflight failure is `not_committed`;
after a network attempt, a failure is conservatively `unknown`. Interruptions
also close the connection and do not authorize a retry.

`priv/examples/ruuvi-raw-v2.observation.json` is the documented RAWv2 fixture for
trying the import workflow. Its timestamp and provenance explicitly describe
fixture data; it is not a live scan or trusted physical-device association.

Finite requests have a five-second absolute deadline and a 4 MiB response limit.
Streams have a 1–300 second deadline, 1–1000 event ceiling and 32 KiB frame limit;
deadline expiry is explicit. Response headers are admitted at 32 fields/8 KiB.
Compressed responses and undeclared media/version envelopes are rejected. Raw
exports use their original response bytes; ordinary JSON output preserves native
wide integers and `1` versus `1.0` through the WoTEx JSON boundary.

`observe` emits one `wtr.property.v1` JSON object per sample: native `value`, stable
`event`, decimal `generation` and opaque `cursor`. Save the cursor to resume after
that sample. Replayed metadata stays stable even when encrypted cursors differ.
There is no automatic reconnect. Unavailable samples close the stream; after
recovery, start a fresh snapshot without a cursor. This is observation of committed
Thing state; imports require explicit association and materialisation first.
Physical scanner/Action commands remain unsupported in capabilities.

## Optional browser interface

Build this composition with `WOTEX_TRACKER_UI=1`. It adds the shared
`wotex_tracker_ui` package and compiles `ui/`; the ordinary host build excludes
both. The two compositions use separate lockfiles, dependency directories and
build directories. Each needs its own dependency resolution and complete check:

```sh
WOTEX_PATH_DEPS=1 WOTEX_TRACKER_UI=1 MIX_ENV=test mise exec -- mix deps.get
WOTEX_PATH_DEPS=1 WOTEX_TRACKER_UI=1 MIX_ENV=test mise exec -- mix check --no-retry
```

The browser listener needs a second private configuration file, selected at
runtime by `WOTEX_TRACKER_UI_CONFIG`. Its closed `wtr.browser.v1` document has
`listen`, `exposure`, `public_origin`, `secret_key_base`, optional `tls` and an
optional `model`.
The file has the same 0600/0700, regular-file, no-symlink and 64 KiB requirements
as the service configuration. Supply a fresh random secret of 64–128 bytes,
distinct from the service instance key. The origin is explicit; loopback mode
requires the listener's port and its numeric address or `localhost`. Proxy/TLS
mode requires an HTTPS public origin and sets Secure cookies. Direct TLS uses
the same certificate/key fields as the service. An artifact without UI support
rejects browser configuration at startup.

Omitting `model` disables prompted graphs. To enable the public OpenAI Responses
adapter, add one `model` object to that private browser file. It requires
`provider: "openai_responses"`, an HTTPS `endpoint` ending in `/v1/responses`,
an explicit `model` ID and `api_key`, and
`disclosure: "question_schema_utc"`. The adapter sends only the typed question,
permitted measurement names/units, closed choices and current UTC time; it never
sends readings, asset identity or a service bearer. Set finite budgets:
`timeout_ms` (1000–10000), `max_request_bytes` (1024–8192),
`max_response_bytes` (1024–32768), `max_output_tokens` (128–2048),
`max_concurrent` (1–4), `max_requests_per_minute` (1–60),
`max_cost_micro_usd` (1–100000), and the provider/model's current
`input_price_micro_usd_per_million` and
`output_price_micro_usd_per_million` (each 1–100000000). The byte and token
limits provide a conservative cost preflight; returned usage is checked again.
The host makes one request with no provider tools, retries or stored response.
Failure leaves the structured form and existing result usable. Keep the key in
the 0600 file and refresh the price inputs when provider pricing changes.

The optional browser also offers **Operational history** from the asset list to
administrators. It reads at most 25 recent local telemetry samples per page,
with event filtering and previous/next navigation pinned to the collector's
volatile epoch. Each read checks current admin authority. Refresh starts a new
snapshot; collector restart or retention expiry requires a fresh first page.
The route needs no external metrics service and is absent from the headless host.

After creating `_build/local` with the CLI above, create a loopback browser
configuration without printing its secret or replacing an existing file:

```sh
umask 077
WOTEX_PATH_DEPS=1 WOTEX_TRACKER_UI=1 MIX_ENV=test mise exec -- mix run --no-start -e '
document = %{
  "schema" => "wtr.browser.v1",
  "listen" => %{"ip" => "127.0.0.1", "port" => 4040},
  "exposure" => "loopback",
  "public_origin" => "http://127.0.0.1:4040",
  "secret_key_base" => Base.encode64(:crypto.strong_rand_bytes(64))
}
File.write!("_build/local/browser.json", Wotex.Tracker.Service.Codec.encode!(document), [:exclusive])
'
WOTEX_PATH_DEPS=1 WOTEX_TRACKER_UI=1 MIX_ENV=test \
  WOTEX_TRACKER_CONFIG="$PWD/_build/local/config.json" \
  WOTEX_TRACKER_UI_CONFIG="$PWD/_build/local/browser.json" \
  mise exec -- mix run --no-halt
```

Open `http://127.0.0.1:4040`, sign in with scope `workshop` and the private
operator token, then choose Setup. Choose a preformed Observation JSON capture
up to 256 KiB to import it from the browser. The CLI and API accept the same
admission contract. The browser presents retained evidence, explicit ownership
confirmation, enrollment, later observation association and Thing provisioning.
After association, the asset page identifies prior measurements and offers an
explicit Thing update. Asset details show actual measurements,
quality, UTC observation time and bounded measurement history. No physical
scanner, positioning, protection, Action or battery-percentage behavior is
invented for the environmental fixture.

Credentials stay in a bounded volatile server store. Encrypted HttpOnly,
SameSite=Strict cookies and signed LiveView payloads carry only an opaque session
reference. Sessions expire within one hour; service authorization is checked on
every request and idle views recheck within five seconds. Logout invalidates
existing views. Restart requires sign-in. A disconnected view identifies its
display as potentially out of date; operation references stay in page URLs so
reconnecting can recover a retained receipt without repeating a mutation.

Source tests cover the shared workflow and actual host HTTP authentication,
static assets, cookie attributes and WebSocket-origin denial. Browser review
includes desktop and narrow viewport layouts. The composed host also checks
saved-dashboard listing and detail routes. The UI-enabled bundle passes its
local software lifecycle probe as described below. Remote-service presentation,
complete accessibility and full product workflows remain unqualified.

## Bundled release and local OCI qualification

The repository artifact harness builds normal immutable packages in a temporary
signed local registry, then assembles the host against ordinary production
requirements. It never enables production path dependencies. Public sibling
release availability is a separate, currently unpassed gate.

From the repository root, with Docker, the declared mise toolchains and a Rust
toolchain installed:

```sh
MIX_ENV=test WOTEX_PATH_DEPS=1 mise exec -- mix run --no-start scripts/qualify_source.exs --host
MIX_ENV=test WOTEX_PATH_DEPS=1 mise exec -- mix run --no-start scripts/qualify_source.exs --ui
```

The harness builds bundled ERTS releases under `_build/releases/` for Darwin
ARM64 and Linux ARM64, plus the local image
`wotex-tracker:0.1.0-linux-arm64-local`. `--ui` builds the separate UI package,
checks fresh, locked and minimum production consumers on both supported
Elixir/OTP lanes, and assembles `wotex_tracker_ui-0.1.0-{darwin,linux}-arm64.tar.gz`
under `_build/releases/` and `wotex-tracker-ui:0.1.0-linux-arm64-local` locally.
Its exact report is `_build/verification/ui-consumer.json`. The UI bundle keeps
the same release command and uses both private service and browser configuration
files described above. The release probe signs into the browser, checks an
enrolled asset and measurements, and verifies the old browser session is denied
after restart. Linux also exercises the read-only, non-root container. The UI
package has no endpoint or listener when consumed alone.

Linux uses the pinned Debian Bookworm
builder with Elixir 1.18.4 / OTP 27.3.4.15 and Hex 2.5.1. The runtime image is a
separate pinned Debian base with the libraries needed by the bundled ERTS; it
contains no external Elixir, Erlang, Mix or C compiler. Artifact, base-image,
compiler and dependency identities are recorded in
`_build/verification/host-consumer.json`. Runtime
license and notice files are retained under `licenses/` in each release. No command
publishes an image or release. Artifacts are specific to their OS/architecture.

Extract a release on its declared platform, provision configuration using its
`bin/trackerctl`, then run:

```sh
WOTEX_TRACKER_CONFIG=/absolute/private/instance/config.json bin/wotex_tracker start
```

ERTS and the CLI implementation are bundled; no system language runtime is
needed. Distribution is disabled by the release environment template. Stop the
foreground service with SIGTERM; retain its private data directory and instance
key across restart.

For a local container sidecar, create a private host directory and provision it
using the image's CLI. The example uses the current Unix UID/GID so mounted
files remain owned by their operator:

```sh
mkdir -m 700 runtime
docker run --rm --user "$(id -u):$(id -g)" -v "$PWD/runtime:/runtime" \
  --entrypoint /opt/wotex/bin/trackerctl wotex-tracker:0.1.0-linux-arm64-local \
  --scope workshop init --directory /runtime/instance --instance-id workshop \
  --bind 127.0.0.1 --port 4000
docker run --rm --name tracker --user "$(id -u):$(id -g)" --network none \
  --read-only --tmpfs /tmp:rw,nosuid,nodev,mode=1777 -v "$PWD/runtime:/runtime" \
  -e WOTEX_TRACKER_CONFIG=/runtime/instance/config.json \
  wotex-tracker:0.1.0-linux-arm64-local
```

In another terminal, `docker exec tracker /opt/wotex/bin/trackerctl --url
http://127.0.0.1:4000 --scope workshop --token-file
/runtime/instance/operator.token capabilities` uses the machine boundary.
`docker stop --time 10 tracker` requests graceful shutdown. This loopback example
opens no host port. Remote exposure needs explicit TLS or the documented trusted
proxy configuration. The default image user is UID/GID 10001 when not overridden;
mounted configuration and data must be private and accessible to that user.

The black-box artifact probe exercises HTTP/OpenAPI/SSE, history, active-stream
SIGTERM shutdown, restart, exact receipt replay, retained revocation, process-kill
recovery and SQLite's real page ceiling. Linux additionally runs as a non-root
user on a read-only container root and checks an unwritable data destination.
The probe imports no BEAM source and runs without external BEAM tools in PATH.
This is software artifact evidence, not physical power-loss or device qualification.
