# Repository working agreements

## Repository visibility

- Never change this repository's visibility on any hosting provider.
- Treat visibility changes as manual, user-only actions even when another task
  depends on one.

## Implementation languages

- Do not add Python source, scripts, tests, generators, consumers, CLIs, build
  steps, runtime dependencies or container packages.
- When work touches an existing Python surface, migrate it to Elixir/Erlang or
  the native language of its owning target instead of extending it. Changes that
  only remove Python are allowed.
- Prefer Elixir for repository orchestration, contract generation, acceptance
  consumers and host tooling. Use Erlang where direct OTP primitives make the
  boundary clearer. Platform applications use their established native
  language.
- Keep independent acceptance consumers outside the production domain modules;
  language independence is not a substitute for protocol-boundary independence.
