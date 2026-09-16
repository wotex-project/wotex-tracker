[
  parallel: false,
  skipped: false,
  tools: [
    {:formatter, command: "mix format --check-formatted"},
    {:compiler, command: "mix compile --warnings-as-errors"},
    {:ex_unit, command: "mix coveralls"},
    {:credo, command: "mix credo --strict"},
    {:boundary_credo,
     command: "mix credo --strict ../../scripts/openapi.exs ../../scripts/http_consumer.exs"},
    {:dialyzer, command: "mix dialyzer"},
    {:ex_doc, command: "mix docs --warnings-as-errors"},
    {:mix_audit, command: "mix deps.audit"},
    {:stack_language, command: "mix run --no-start ../../scripts/check_stack_language.exs"},
    {:archive, command: "mix run ../../scripts/check_archive.exs"},
    {:openapi, command: "mix run --no-start ../../scripts/openapi.exs --check"},
    {:licenses, command: "mix run ../../scripts/check_licenses.exs"}
  ]
]
