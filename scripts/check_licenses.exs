allowed = ~w(Apache-2.0 MIT BSD-2-Clause BSD-3-Clause ISC)

for dep <- Mix.Dep.load_and_cache() do
  metadata = Path.join(dep.opts[:dest], "hex_metadata.config")

  licenses =
    case :file.consult(String.to_charlist(metadata)) do
      {:ok, terms} ->
        Map.new(terms)["licenses"] || []

      _ ->
        Mix.Dep.in_dependency(dep, fn _ ->
          Mix.Project.config() |> Keyword.get(:package, []) |> Map.new() |> Map.get(:licenses, [])
        end)
    end

  # yamerl 0.10.0 LICENSE is the two-clause BSD text; its Hex label predates SPDX.
  licenses =
    Enum.map(licenses, fn label -> if label == "BSD 2-Clause", do: "BSD-2-Clause", else: label end)

  if licenses == [] or not Enum.all?(licenses, &(&1 in allowed)) do
    Mix.raise("Review dependency license: #{dep.app} #{inspect(licenses)}")
  end

  IO.puts("#{dep.app}: #{Enum.join(licenses, ", ")}")
end
