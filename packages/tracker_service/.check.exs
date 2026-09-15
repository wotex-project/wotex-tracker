[
  parallel: false,
  skipped: false,
  tools: [
    {:formatter, command: "mix format --check-formatted"},
    {:compiler, command: "mix compile --warnings-as-errors"},
    {:ex_unit, command: "mix coveralls"},
    {:credo, command: "mix credo --strict"},
    {:dialyzer, command: "mix dialyzer"},
    {:ex_doc, command: "mix docs --warnings-as-errors"},
    {:mix_audit, command: "mix deps.audit"},
    {:archive, command: "mix run ../../scripts/check_archive.exs"},
    {:openapi, command: "../../_build/openapi-venv/bin/python ../../scripts/openapi.py --check"},
    {:licenses, command: "mix run ../../scripts/check_licenses.exs"}
  ]
]
