defmodule Wotex.Tracker.StackLanguageCheck do
  @moduledoc false

  @root_extensions ~w(.ex .exs .sh .bash .zsh .fish .mk .toml .yml .yaml)
  @python_manifests ~w(Pipfile Pipfile.lock pyproject.toml poetry.lock uv.lock pdm.lock .python-version)
  @excluded_content_paths MapSet.new(["scripts/check_stack_language.exs"])

  def run! do
    root = repository_root!()
    files = tracked_and_unignored_files(root)

    violations =
      files
      |> Enum.flat_map(&path_violations/1)
      |> Kernel.++(Enum.flat_map(files, &content_violations(root, &1)))
      |> Enum.sort()

    if violations != [] do
      Mix.raise("Stack language policy failed:\n" <> Enum.join(violations, "\n"))
    end

    IO.puts("Stack language policy passes for #{length(files)} tracked and unignored files")
  end

  defp repository_root! do
    case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
      {root, 0} -> String.trim(root)
      {output, _status} -> Mix.raise("Cannot locate repository root: #{String.trim(output)}")
    end
  end

  defp tracked_and_unignored_files(root) do
    {output, 0} =
      System.cmd(
        "git",
        ["-C", root, "ls-files", "-co", "--exclude-standard", "-z"],
        stderr_to_stdout: true
      )

    output
    |> String.split(<<0>>, trim: true)
    |> Enum.uniq()
    |> Enum.filter(&File.regular?(Path.join(root, &1)))
  end

  defp path_violations(path) do
    basename = Path.basename(path)

    cond do
      Path.extname(path) in ~w(.py .pyi .pyw) -> ["#{path}: Python source is forbidden"]
      requirements_manifest?(basename) -> ["#{path}: Python requirement manifests are forbidden"]
      basename in @python_manifests -> ["#{path}: Python environment manifests are forbidden"]
      true -> []
    end
  end

  defp requirements_manifest?(basename),
    do: String.starts_with?(basename, "requirements") and String.ends_with?(basename, ".txt")

  defp content_violations(root, path) do
    if active_surface?(path) and path not in @excluded_content_paths do
      bytes = File.read!(Path.join(root, path))

      if String.valid?(bytes) and
           Regex.match?(~r/\bpython(?:\d+(?:\.\d+)*)?\b|\bpip(?:3)?\s+install\b/i, bytes) do
        ["#{path}: Python interpreter or package tooling is forbidden"]
      else
        []
      end
    else
      []
    end
  end

  defp active_surface?(path) do
    extension = Path.extname(path)
    basename = Path.basename(path)

    extension in @root_extensions or
      String.starts_with?(path, ".github/") or
      String.starts_with?(path, "hosts/app/bin/") or
      String.starts_with?(path, "scripts/") or
      String.starts_with?(basename, "Dockerfile") or basename in ~w(Makefile Justfile)
  end
end

Wotex.Tracker.StackLanguageCheck.run!()
