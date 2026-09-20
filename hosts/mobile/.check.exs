[
  parallel: false,
  skipped: false,
  tools: [
    {:formatter, command: "mix format --check-formatted"},
    {:compiler, command: "mix compile --warnings-as-errors"},
    {:native_format,
     command: "cargo fmt --manifest-path ../../native/protocol_consumer/Cargo.toml --check"},
    {:native_compile,
     command:
       "cargo build --release --locked --manifest-path ../../native/protocol_consumer/Cargo.toml",
     env: %{"RUSTFLAGS" => "-Dwarnings"}},
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
