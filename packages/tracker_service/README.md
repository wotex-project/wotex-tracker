# Tracker service components

Explicitly started service components live here. Loading this package starts no
Tracker listener or store. The pure `wotex_tracker` package has no dependency on
this package. The durable-store contract and current acceptance scope are in
the repository's `docs/contracts/service-v1.md`.

Development uses `WOTEX_PATH_DEPS=1 MIX_ENV=test mise exec -- mix check --no-retry`
from this directory. Production resolves normal package artifacts. The local
workspace switch is rejected in production.

Install the independent OpenAPI/client verification tools from the repository
root before running the gate:

```sh
python3 -m venv _build/openapi-venv
_build/openapi-venv/bin/pip install -r scripts/requirements-openapi.txt
```

`Wotex.Tracker.Service.new/1` takes an explicit `Store` handle, `Credentials`
value and public `base_url` origin. It loads the packaged RAWv2 catalogue and
environmental model. The host owns time, credential custody and supervision.
Every facade operation authenticates an ephemeral bearer token and exact scope.

The facade supports imported observations, public inspection and paginated
snapshots, encrypted event cursors, privileged byte-preserving raw exports,
operator-confirmed enrollment, materialisation, revocation and operation-status
lookup. Mutations take a lowercase UUIDv4 operation ID and a decimal-string
expected generation. The original committed receipt is replayed before new
profile/model work, including its generated Thing ID. Unknown outcomes require
receipt lookup; they do not authorize automatic physical Action retries.

Enrollment issues a random UUID pseudonym for an explicitly confirmed observation.
It does not authenticate the radio device or associate future packets implicitly.
Materialisation persists a validated upstream TD, initial state and private
lineage together. Forms use the configured origin and the reserved service API
path. Runtime Property handlers are the next integration slice; the current
HTTP capability report marks Runtime interactions unsupported. No Directory
destination or publication effect is implicit.

An `enroll` grant can derive initial state/evidence for the same Thing in its
materialisation transaction. It cannot import observations or export raw data.
Resource reads need `read`; raw exports need `raw`; revocation needs `admin`.
Missing scanner/rule/analytics implementations remain explicitly unsupported.

## Explicit HTTP instance

The package includes a caller-started Bandit/Plug listener. It has no application
callback. With an existing private absolute `directory` and admitted `credentials`:

```elixir
{:ok, server} = Wotex.Tracker.Service.HTTP.Server.start_link(
  directory: directory,
  credentials: credentials,
  ip: {127, 0, 0, 1},
  port: 4000,
  exposure: :loopback,
  public_origin: :listener
)
```

Use `port: 0` only when an ephemeral port is wanted; `listener_info/1` returns
the actual address. Production TD URLs need a stable configured origin. TLS mode
requires `exposure: :tls`, an HTTPS `public_origin` and absolute `tls` certificate
and key paths. Explicit `:proxy` mode requires an HTTPS public origin and a
protected proxy-to-listener network; forwarded headers never supply authority or
Forms. No remote exposure is inferred.

OpenAPI **3.1.0**, contract revision **1.0.0**, is packaged at
`priv/openapi/v1.json` and served at `/api/v1/openapi.json`. Liveness is
`/health/live`; authenticated resources are under `/api/v1/scopes/{scope}`.
Use `Authorization: Bearer …`, and a UUIDv4 `Idempotency-Key` for POST mutations.
JSON responses have `schema: wtr.response.v1` and `data` or `error`. Unknown
mutation outcomes use HTTP 202; query the same operation ID. Raw exports use
their own media types and preserve bytes/native types.

SSE is `/events/stream` below the scope. Supply exactly one initial `cursor`
query parameter or resumed `Last-Event-ID` header. Transport IDs are encrypted
cursors; deduplicate the stable domain `data.id`. Streams close on revocation,
expiry, storage failure or their five-minute lifetime. Reconnect/resnapshot
according to the returned error. Tokens never belong in URLs.

The listener caps 32 requests, 16 streams and 64 connections per instance.
Requests after header admission have a five-second hard deadline; header reads
have a five-second idle timeout and finite byte/count limits. HTTP/2, WebSockets
and compression are disabled in this qualified slice. The caller owns shutdown;
active stream shutdown is tested below the ten-second budget.
