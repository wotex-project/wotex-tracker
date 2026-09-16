[
  parallel: false,
  skipped: false,
  tools: [
    {:formatter, command: "mix format --check-formatted"},
    {:compiler, command: "mix compile --warnings-as-errors"},
    {:cli_compile,
     command: "env WOTEX_TRACKER_CLI_NO_MAIN=1 mix run --no-start scripts/trackerctl.exs"},
    {:cli_credo, command: "mix credo --strict scripts/trackerctl.exs"},
    {:ex_unit, command: "mix coveralls --no-start"},
    {:credo, command: "mix credo --strict"},
    {:dialyzer, command: "mix dialyzer"},
    {:ex_doc, command: "mix docs --warnings-as-errors"},
    {:mix_audit, command: "mix deps.audit"},
    {:licenses, command: "mix run --no-start ../../scripts/check_licenses.exs"}
  ]
]
