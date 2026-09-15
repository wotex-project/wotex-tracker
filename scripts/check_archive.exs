archive =
  Path.join(
    Mix.Project.build_path(),
    "#{Mix.Project.config()[:app]}-#{Mix.Project.config()[:version]}.tar"
  )

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

required_files =
  case Mix.Project.config()[:app] do
    :wotex_tracker ->
      ~w(mix.exs README.md LICENSE NOTICE SECURITY.md CONTRIBUTING.md lib/wotex/tracker/error.ex docs/specs/catalogue.yaml priv/thing_models/environmental-sensor-1.0.0.tm.json)

    :wotex_tracker_service ->
      ~w(mix.exs README.md LICENSE NOTICE lib/wotex/tracker/service/store.ex lib/wotex/tracker/service/http/server.ex priv/schema/1.sql priv/openapi/v1.json)
  end

for required <- required_files do
  if required not in names, do: Mix.raise("Archive missing #{required}")
end

for name <- names do
  if String.starts_with?(name, ~w(hosts/ packages/ _build/ deps/ test/ .git/ .env)) or
       String.ends_with?(name, ~w(.db .db-wal .db-shm .pem)) do
    Mix.raise("Forbidden archive member #{name}")
  end
end

IO.puts(
  "Inspected #{length(names)} archive members; ordinary package dependency metadata built without path switch"
)
