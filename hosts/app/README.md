# Standalone Tracker host

This optional application owns startup of the headless service. The root library
and service package keep their explicit, inert installation contract.

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

`bin/trackerctl` is a Python 3.11+ POSIX client using only the standard library.
It uses the authenticated HTTP API. Tokens are read from a private 0600 file;
they never belong in command arguments, URLs or environment variables. The
client ignores proxy environment variables, verifies HTTPS certificates, follows
no redirects and retries no operation.

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
| `materialize THING --generation 2` | Persist the evidence-backed TD and initial state |
| `list things`, `read THING temperature` | Inspect TDs and read Properties |
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
deadline expiry is explicit. Response headers are admitted at 32 fields/8 KiB
after Python's finite HTTP parser ceiling of 100 fields/64 KiB per line. Compressed
responses and undeclared media/version envelopes are rejected. Raw exports use
their original response bytes; ordinary JSON output preserves native wide
integers and `1` versus `1.0` through Python's numeric types.

Property observation and physical scanner/Action commands are not implemented;
capabilities report their current status.

## Bundled release and local OCI qualification

The repository artifact harness builds normal immutable packages in a temporary
signed local registry, then assembles the host against ordinary production
requirements. It never enables production path dependencies. Public sibling
release availability is a separate, currently unpassed gate.

From the repository root, with Docker, the declared mise toolchains and the
OpenAPI verification environment installed:

```sh
python3 scripts/source_consumer.py --host
```

The harness builds bundled ERTS releases under `_build/releases/` for Darwin
ARM64 and Linux ARM64, plus the local image
`wotex-tracker:0.1.0-linux-arm64-local`. Linux uses the pinned Debian Bookworm
builder with Elixir 1.18.4 / OTP 27.3.4.15 and Hex 2.5.1. The runtime image is a
separate pinned Debian base with runtime libraries and Python; it contains no
installed Elixir, Mix or C compiler. Artifact, base-image, compiler and dependency
identities are recorded in `_build/verification/host-consumer.json`. Runtime
license and notice files are retained under `licenses/` in each release. No command
publishes an image or release. Artifacts are specific to their OS/architecture.

Extract a release on its declared platform, provision configuration using its
`bin/trackerctl`, then run:

```sh
WOTEX_TRACKER_CONFIG=/absolute/private/instance/config.json bin/wotex_tracker start
```

ERTS is bundled; no system Elixir/Erlang installation is needed. The standalone
CLI needs Python 3.11+ on Darwin; Python is included in the container. Distribution
is disabled by the release environment template. Stop the foreground service
with SIGTERM; retain its private data directory and instance key across restart.

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
