# Contributing

Use `mise exec -- elixir --version` to confirm the pinned development runtime. Install development
dependencies with `WOTEX_PATH_DEPS=1 mise exec -- mix deps.get` while the required
WoTEx release is unavailable. This switch selects only the explicit sibling
package directories under `../wotex/packages/` and is rejected in production. It
proves a source cohort, not a release.

Run `MIX_ENV=test WOTEX_PATH_DEPS=1 mise exec -- mix check --no-retry` for the complete local
gate on Elixir 1.20.4 / OTP 29.1.2. Also retain the supported Elixir 1.18.4 /
OTP 27.3.4.15 floor using `mise exec elixir@1.18.4-otp-27 erlang@27.3.4.15 --
mix check --no-retry` and `MIX_ENV=test MIX_BUILD_PATH="$(pwd -P)/_build/otp27/test"`.
Tests must preserve 95% production line coverage, strict analysis and all checks.
Document unpassed runtime, package, host and hardware gates explicitly.

Keep the root library inert. Configuration and time are explicit inputs; hosts
own resources. Add independent protocol expectations and regression tests.
One logical spec milestone per local commit. Do not change repository visibility.
Publishing, pushing, workflows and device flashing are separate operations.
