# WoTEx Tracker mobile host

This independent host will compose the shared LiveView UI, its versioned remote
service client and narrow iOS integrations inside a Mob WebView. It deliberately
uses Elixir 1.19.5 on OTP 27 because Mob 0.9.1 requires Elixir 1.19; the root
library and other hosts retain their Elixir 1.18 floor.

The first executable seam is the bounded offline projection cache. It stores no
bearer credential, access proof, raw evidence, mutation or physical Action. A
cache binding includes the canonical HTTPS origin, principal, scope, credential
ID and a secure-storage installation ID. Switching any binding field purges the
previous account. Entries expire at both their local retention deadline and the
last remotely observed credential expiry. Reads report synchronization age and
completeness and never authorize a remote request.

The cache database belongs under Mob's app-private cache directory and is safe
to lose: an absent or OS-purged cache is an explicit first-use state. The host
must reconstruct the binding from platform secure storage after process start;
ordinary files, preferences and browser storage are not credential stores.

The executable presentation seam runs the shared LiveView router behind a
numeric IPv4 loopback-only Bandit listener. A fresh 32-byte capability appears
only in the initial WebView bootstrap URL; the endpoint replaces it with an
encrypted, signed, HTTP-only, SameSite-strict cookie and requires its digest on
every later HTTP and LiveView admission. Login, logout and session renewal retain
only that host-owned binding. The WebView allow-prefix is the exact local origin,
foreign WebSocket origins fail, external canonical HTTPS links open through the
OS, and no development distribution listener or cookie is configured.

Remote calls remain bounded by the shared client and its exact configured HTTPS
authority. The mobile transport invokes Mob's OS DNS seam before Mint without
allowing resolution to rewrite the authority or request. On ordinary development
hosts, where the Mob NIF is intentionally absent, the transport falls back to
the BEAM resolver so the same closed request path can be tested.

Run the software gate with the host-pinned toolchain:

```sh
WOTEX_PATH_DEPS=1 MIX_ENV=test mise exec -- mix deps.get
WOTEX_PATH_DEPS=1 MIX_ENV=test mise exec -- mix check --no-retry
```

No Xcode project, signed installation, secure-storage bridge, notification
plugin, lifecycle bridge, BLE central bridge, sharing bridge or physical-iPhone
evidence exists in this slice. Offline cache synchronization is not yet wired to
the shared views. Those gates remain explicitly open.
