# Contributing

Use `mise exec -- elixir --version` to confirm the pinned floor. Install development
dependencies with `WOTEX_PATH_DEPS=1 mise exec -- mix deps.get` while the required
WoTEx release is unavailable. This switch selects only the explicit sibling
package directories under `../wotex/packages/` and is rejected in production. It
proves a source cohort, not a release.

Run `MIX_ENV=test WOTEX_PATH_DEPS=1 mise exec -- mix check --no-retry` for the complete local
gate. Repeat with Elixir 1.20.4 / OTP 29.0.4 using `mise exec elixir@1.20.4-otp-29
erlang@29.0.4 -- mix check --no-retry` and `MIX_ENV=test MIX_BUILD_PATH=_build/otp29/test`.
Tests must preserve 95% production line coverage, strict analysis and all checks.
Document unpassed runtime, package, host and hardware gates explicitly.

Keep the root library inert. Configuration and time are explicit inputs; hosts
own resources. Add independent protocol expectations and regression tests.
One logical spec milestone per local commit. Do not change repository visibility.
Publishing, pushing, workflows and device flashing are separate operations.
