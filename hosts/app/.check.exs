[
  parallel: false,
  skipped: false,
  tools: [
    {:formatter, command: "mix format --check-formatted"},
    {:compiler, command: "mix compile --warnings-as-errors"},
    {:cli_compile,
     command: "env WOTEX_TRACKER_CLI_NO_MAIN=1 mix run --no-start scripts/trackerctl.exs"},
    {:cli_credo, command: "mix credo --strict scripts/trackerctl.exs"},
    {:native_format,
     command:
       "zig fmt --check ../../native/protocol_consumer/build.zig ../../native/protocol_consumer/src/main.zig"},
    {:native_test,
     command:
       "env ZIG_GLOBAL_CACHE_DIR=../../_build/zig-global-cache zig build test --build-file ../../native/protocol_consumer/build.zig --cache-dir ../../_build/zig-cache/protocol-consumer"},
    {:native_compile,
     command:
       "env ZIG_GLOBAL_CACHE_DIR=../../_build/zig-global-cache zig build --build-file ../../native/protocol_consumer/build.zig -Doptimize=ReleaseSafe --prefix ../../_build/native/protocol-consumer/darwin --cache-dir ../../_build/zig-cache/protocol-consumer"},
    {:ex_unit, command: "mix coveralls --no-start"},
    {:credo, command: "mix credo --strict"},
    {:dialyzer, command: "mix dialyzer --force-check"},
    {:ex_doc, command: "mix docs --warnings-as-errors"},
    # Same HTTP/2-only Bandit advisory acknowledged in mix.exs.
    {:mix_audit, command: "mix deps.audit --ignore-advisory-ids=GHSA-69m6-wcv4-rwcf"},
    {:stack_language, command: "mix run --no-start ../../scripts/check_stack_language.exs"},
    {:licenses, command: "mix run --no-start ../../scripts/check_licenses.exs"}
  ]
]
