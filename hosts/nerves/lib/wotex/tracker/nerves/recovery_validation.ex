defmodule Wotex.Tracker.Nerves.RecoveryValidation do
  @moduledoc """
  Read-only admission for an offline restored appliance storage tree.

  A candidate must retain the initialized storage marker, match the service
  instance and fixed runtime data path, contain no interrupted marker generation
  or SQLite sidecars, and pass the current application's supported-schema and
  integrity checks. The result contains paths and validation facts, never
  credentials, database contents or storage identity.
  """

  import Bitwise

  alias Exqlite.Sqlite3
  alias Wotex.Tracker.Service.{Credentials, Schema, StorePath}
  alias Wotex.Tracker.Service.HTTP.FileConfig

  @runtime_root "/root/tracker"
  @marker_fields ~w(schema state instance_id storage_id data_directory database)
  @current_schema 8

  @doc "Parses one absolute offline recovery-tree argument."
  @spec run([String.t()]) :: {:ok, map()} | {:error, atom()}
  def run(arguments), do: run(arguments, @runtime_root)

  @doc false
  @spec run([String.t()], String.t()) :: {:ok, map()} | {:error, atom()}
  def run(["--" | arguments], runtime_root), do: run(arguments, runtime_root)

  def run(arguments, runtime_root) when is_list(arguments) do
    {options, rest, invalid} = OptionParser.parse(arguments, strict: [directory: :string])
    values = Map.new(options)

    with true <- invalid == [] and rest == [],
         directory when is_binary(directory) <- values[:directory],
         true <- absolute_path?(directory),
         {:ok, result} <- validate(directory, runtime_root) do
      {:ok, result}
    else
      false -> {:error, :invalid_arguments}
      nil -> {:error, :invalid_arguments}
      {:error, _} = error -> error
      _ -> {:error, :invalid_arguments}
    end
  end

  def run(_, _), do: {:error, :invalid_arguments}

  @doc "Validates a staged initialized tree without mutating it."
  @spec validate(term(), term()) :: {:ok, map()} | {:error, :recovery_required}
  def validate(directory, runtime_root) when is_binary(directory) and is_binary(runtime_root) do
    runtime_data = Path.join(runtime_root, "data")
    config_path = Path.join(directory, "config.json")
    marker_path = Path.join(directory, "storage.json")
    staged_data = Path.join(directory, "data")
    database_path = Path.join(staged_data, "tracker.db")

    with true <- absolute_path?(directory) and absolute_path?(runtime_root),
         :ok <- StorePath.private_directory(directory),
         {:ok, options} <- FileConfig.load(config_path),
         true <- options[:directory] == runtime_data and options[:exposure] in [:loopback, :tls],
         :ok <- validate_tls(options[:tls], directory, runtime_root),
         instance = Credentials.instance_id(options[:credentials]),
         {:ok, marker} <- read_marker(marker_path),
         true <- initialized_marker?(marker, instance, runtime_data),
         {:error, :enoent} <- File.lstat(Path.join(directory, "storage.json.next")),
         :ok <- StorePath.private_directory(staged_data),
         :ok <- private_database(database_path),
         :ok <- sidecars_absent(database_path),
         {:ok, schema} <- validate_database(database_path) do
      {:ok,
       %{
         "schema" => "wtr.nerves-recovery-validation.v1",
         "config_file" => config_path,
         "storage_marker" => marker_path,
         "database_file" => database_path,
         "storage_state" => "initialized",
         "database_schema" => Integer.to_string(schema),
         "integrity_check" => "ok"
       }}
    else
      _ -> {:error, :recovery_required}
    end
  end

  def validate(_, _), do: {:error, :recovery_required}

  defp read_marker(path) do
    with {:ok, marker} <- FileConfig.read_document(path),
         true <-
           is_map(marker) and map_size(marker) == length(@marker_fields) and
             Enum.sort(Map.keys(marker)) == Enum.sort(@marker_fields) do
      {:ok, marker}
    else
      _ -> {:error, :recovery_required}
    end
  end

  defp initialized_marker?(marker, instance, runtime_data) do
    marker["schema"] == "wtr.storage.v1" and marker["state"] == "initialized" and
      marker["instance_id"] == instance and marker["data_directory"] == runtime_data and
      marker["database"] == "tracker.db" and storage_id?(marker["storage_id"])
  end

  defp storage_id?(value) when is_binary(value) do
    case Base.decode16(value, case: :lower) do
      {:ok, bytes} -> byte_size(bytes) == 16
      :error -> false
    end
  end

  defp storage_id?(_), do: false

  defp validate_tls(nil, _directory, _runtime_root), do: :ok

  defp validate_tls(%{certfile: cert, keyfile: key}, directory, runtime_root) do
    if Enum.all?([cert, key], &private_staged_material?(&1, directory, runtime_root)),
      do: :ok,
      else: {:error, :recovery_required}
  end

  defp validate_tls(_, _, _), do: {:error, :recovery_required}

  defp private_staged_material?(runtime_path, directory, runtime_root) do
    with true <- under_root?(runtime_path, runtime_root),
         relative <- Path.relative_to(runtime_path, runtime_root),
         staged_path <- Path.join(directory, relative),
         :ok <- StorePath.private_directory(Path.dirname(staged_path)),
         {:ok, %{type: :regular, links: 1, size: size, mode: mode}} <- File.lstat(staged_path) do
      size in 1..65_536 and (mode &&& 0o777) == 0o600
    else
      _ -> false
    end
  end

  defp private_database(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular, links: 1, size: size, mode: mode}}
      when size > 0 and (mode &&& 0o777) == 0o600 ->
        :ok

      _ ->
        {:error, :recovery_required}
    end
  end

  defp sidecars_absent(path) do
    if Enum.all?([path <> "-wal", path <> "-shm"], &(File.lstat(&1) == {:error, :enoent})),
      do: :ok,
      else: {:error, :recovery_required}
  end

  defp validate_database(path) do
    case Sqlite3.open(path, mode: :readonly) do
      {:ok, database} ->
        try do
          case Schema.validate_current(database) do
            :ok -> {:ok, @current_schema}
            _ -> {:error, :recovery_required}
          end
        after
          Sqlite3.close(database)
        end

      _ ->
        {:error, :recovery_required}
    end
  end

  defp absolute_path?(path) when is_binary(path) and byte_size(path) in 2..4_096,
    do: Path.type(path) == :absolute and Path.expand(path) == path and Path.dirname(path) != path

  defp absolute_path?(_), do: false

  defp under_root?(path, root) when is_binary(path),
    do: absolute_path?(path) and String.starts_with?(path, root <> "/")

  defp under_root?(_, _), do: false
end
