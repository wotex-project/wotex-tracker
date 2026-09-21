[
  parallel: false,
  skipped: false,
  tools: [
    {:formatter, command: "mix format --check-formatted"},
    {:compiler, command: "mix compile --warnings-as-errors"},
    {:native_format,
     command:
       "zig fmt --check ../../native/protocol_consumer/build.zig ../../native/protocol_consumer/src/main.zig ios/build.zig ios/build_device.zig ios/build_graph.zig native/driver_table/build.zig priv/generated/driver_tab_ios.zig"},
    {:native_driver_table,
     command:
       "zig build test --build-file native/driver_table/build.zig -Doptimize=ReleaseSafe --cache-dir ../../_build/zig-cache/mobile-driver-table --global-cache-dir ../../_build/zig-global-cache"},
    {:native_test,
     command:
       "zig build test --build-file ../../native/protocol_consumer/build.zig --cache-dir ../../_build/zig-cache/protocol-consumer --global-cache-dir ../../_build/zig-global-cache"},
    {:native_compile,
     command:
       "zig build --build-file ../../native/protocol_consumer/build.zig -Doptimize=ReleaseSafe --prefix ../../_build/native/protocol-consumer/darwin --cache-dir ../../_build/zig-cache/protocol-consumer --global-cache-dir ../../_build/zig-global-cache"},
    {:ex_unit, command: "mix coveralls --no-start"},
    {:integrated_product, command: "mix run --no-start scripts/integrated_product.exs"},
    {:credo, command: "mix credo --strict"},
    {:dialyzer, command: "mix dialyzer --force-check"},
    {:ex_doc, command: "mix docs --warnings-as-errors"},
    {:mix_audit, command: "mix deps.audit"},
    {:stack_language, command: "mix run --no-start ../../scripts/check_stack_language.exs"},
    {:licenses, command: "mix run --no-start ../../scripts/check_licenses.exs"}
  ]
]
