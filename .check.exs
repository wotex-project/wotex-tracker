[
  parallel: false,
  skipped: false,
  tools: [
    {:formatter, command: "mix format --check-formatted"},
    {:compiler, command: "mix compile --warnings-as-errors"},
    {:ex_unit, command: "mix coveralls"},
    {:credo, command: "mix credo --strict"},
    {:dialyzer, command: "mix dialyzer --force-check"},
    {:ex_doc, command: "mix docs --warnings-as-errors"},
    {:mix_audit, command: "mix deps.audit"},
    {:stack_language, command: "mix run --no-start scripts/check_stack_language.exs"},
    {:docs_contracts, command: "mix run scripts/check_docs.exs"},
    {:archive, command: "mix run scripts/check_archive.exs"},
    {:licenses, command: "mix run scripts/check_licenses.exs", env: %{"MIX_ENV" => "test"}}
  ]
]
