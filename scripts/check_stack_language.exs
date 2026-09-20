defmodule Wotex.Tracker.StackLanguageCheck do
  @moduledoc false

  @root_extensions ~w(.ex .exs .erl .hrl .escript .sh .bash .zsh .fish .mk .cmake .toml .yml .yaml .zig .rs .c .h .cc .cpp .hpp .js .mjs .cjs .jsx .ts .tsx .ipynb)
  @python_extensions ~w(.py .pyi .pyw .pyc .pyo .pyd .pyx .pxd .pxi .pyz .whl .egg)
  @python_manifests ~w(Pipfile Pipfile.lock pyproject.toml poetry.lock uv.lock pdm.lock .python-version .python-versions tox.ini pytest.ini)
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
      Path.extname(path) in @python_extensions ->
        ["#{path}: Python source or artifacts are forbidden"]

      "__pycache__" in Path.split(path) ->
        ["#{path}: Python cache is forbidden"]

      requirements_manifest?(basename) ->
        ["#{path}: Python requirement manifests are forbidden"]

      basename in @python_manifests ->
        ["#{path}: Python environment manifests are forbidden"]

      true ->
        []
    end
  end

  defp requirements_manifest?(basename),
    do:
      String.starts_with?(basename, "requirements") and
        String.ends_with?(basename, [".txt", ".in"])

  defp content_violations(root, path) do
    if path not in @excluded_content_paths do
      bytes = File.read!(Path.join(root, path))

      if String.valid?(bytes) and (active_surface?(path) or String.starts_with?(bytes, "#!")) and
           Regex.match?(~r/\b(?:python(?:\d+(?:\.\d+)*)?|pypy[23]?|pip[23]?)\b/i, bytes) do
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
      "bin" in Path.split(path) or
      String.starts_with?(path, "scripts/") or
      String.starts_with?(basename, "Dockerfile") or
      basename in ~w(Makefile Justfile CMakeLists.txt package.json package-lock.json)
  end
end

Wotex.Tracker.StackLanguageCheck.run!()
