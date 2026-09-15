archive =
  Path.join(Mix.Project.build_path(), "wotex_tracker-#{Mix.Project.config()[:version]}.tar")

{output, status} =
  System.cmd("env", ["-u", "WOTEX_PATH_DEPS", "mix", "hex.build", "--output", archive],
    stderr_to_stdout: true
  )

if status != 0, do: Mix.raise("Archive build failed: #{output}")

{:ok, outer} = :erl_tar.extract(String.to_charlist(archive), [:memory])

contents =
  Enum.find_value(outer, fn {name, bytes} -> if name == ~c"contents.tar.gz", do: bytes end)

{:ok, files} = :erl_tar.extract({:binary, contents}, [:memory, :compressed])
names = Enum.map(files, fn {name, _} -> List.to_string(name) end)

for required <-
      ~w(mix.exs README.md LICENSE NOTICE SECURITY.md CONTRIBUTING.md lib/wotex/tracker/error.ex docs/specs/catalogue.yaml priv/thing_models/environmental-sensor-1.0.0.tm.json) do
  if required not in names, do: Mix.raise("Archive missing #{required}")
end

for name <- names do
  if String.starts_with?(name, ~w(hosts/ packages/ _build/ deps/ test/ .git/ .env)) do
    Mix.raise("Forbidden archive member #{name}")
  end
end

IO.puts(
  "Inspected #{length(names)} archive members; ordinary package dependency metadata built without path switch"
)
