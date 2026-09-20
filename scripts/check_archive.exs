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
project_root = Mix.Project.project_file() |> Path.dirname() |> Path.expand()

package_sources =
  ~w(lib priv)
  |> Enum.flat_map(fn directory ->
    project_root
    |> Path.join("#{directory}/**/*")
    |> Path.wildcard(match_dot: true)
  end)
  |> Enum.filter(&File.regular?/1)
  |> Enum.map(&Path.relative_to(&1, project_root))
  |> Enum.sort()

required_files =
  case Mix.Project.config()[:app] do
    :wotex_tracker ->
      ~w(mix.exs README.md LICENSE NOTICE SECURITY.md CONTRIBUTING.md docs/specs/catalogue.yaml)

    :wotex_tracker_service ->
      ~w(mix.exs README.md LICENSE NOTICE)

    :wotex_tracker_ui ->
      ~w(mix.exs README.md LICENSE NOTICE)
  end
  |> Kernel.++(package_sources)
  |> Enum.uniq()

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
  "Inspected #{length(names)} archive members and #{length(package_sources)} package-owned source/assets; ordinary package dependency metadata built without path switch"
)
