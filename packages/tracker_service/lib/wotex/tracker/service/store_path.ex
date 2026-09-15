defmodule Wotex.Tracker.Service.StorePath do
  @moduledoc false
  import Bitwise

  def database(directory) do
    with :ok <- private_directory(directory),
         path = Path.join(directory, "tracker.db"),
         :ok <- regular_or_missing(path),
         :ok <- regular_or_missing(path <> "-wal"),
         :ok <- regular_or_missing(path <> "-shm"),
         :ok <- create_private(path) do
      {:ok, path}
    end
  end

  def private_directory(directory)
      when is_binary(directory) and byte_size(directory) in 1..4096 do
    with true <- Path.type(directory) == :absolute and Path.expand(directory) == directory,
         true <- no_symlinks?(directory),
         {:ok, stat} <- File.lstat(directory),
         true <- stat.type == :directory and (stat.mode &&& 0o077) == 0 do
      :ok
    else
      _ -> {:error, :unsafe_path}
    end
  end

  def private_directory(_), do: {:error, :unsafe_path}

  def backup_target(path) when is_binary(path) and byte_size(path) in 1..4096 do
    with :ok <- private_directory(Path.dirname(path)),
         true <- Path.expand(path) == path,
         {:error, :enoent} <- File.lstat(path) do
      :ok
    else
      _ -> {:error, :unsafe_path}
    end
  end

  def backup_target(_), do: {:error, :unsafe_path}

  defp no_symlinks?(directory) do
    directory
    |> Path.split()
    |> Enum.scan(&Path.join(&2, &1))
    |> Enum.all?(fn path -> match?({:ok, %{type: :directory}}, File.lstat(path)) end)
  end

  defp regular_or_missing(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular, links: 1, mode: mode}} when (mode &&& 0o077) == 0 -> :ok
      {:error, :enoent} -> :ok
      _ -> {:error, :unsafe_path}
    end
  end

  defp create_private(path) do
    case File.open(path, [:write, :exclusive]) do
      {:ok, file} ->
        File.close(file)
        File.chmod(path, 0o600)

      {:error, :eexist} ->
        :ok

      {:error, _} ->
        {:error, :storage_unavailable}
    end
  end
end
