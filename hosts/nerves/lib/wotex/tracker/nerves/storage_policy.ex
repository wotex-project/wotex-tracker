defmodule Wotex.Tracker.Nerves.StoragePolicy do
  @moduledoc """
  Fails closed when initialized appliance storage disappears or becomes unsafe.

  Offline provisioning creates a private marker in the writable Tracker root.
  Its `prepared` state permits exactly one empty-store initialization. After the
  service has opened and checked SQLite, the marker is atomically advanced to
  `initialized`. Later boots require the same non-empty private database; the
  service itself remains responsible for schema compatibility and integrity.
  """

  import Bitwise
  alias Wotex.Tracker.Service.{Codec, StorePath}
  alias Wotex.Tracker.Service.HTTP.FileConfig

  @marker "storage.json"
  @next "storage.json.next"
  @fields ~w(schema state instance_id storage_id data_directory database)
  @states ~w(prepared initialized)
  @storage_failures ~w(busy storage_corrupt storage_full storage_unavailable unsafe_path unsupported_schema)a

  @doc "Creates one exclusive prepared-storage marker under an existing private root."
  @spec provision(term(), term(), term()) ::
          {:ok, String.t()}
          | {:error, :invalid_configuration | :configuration_exists | :provisioning_failed}
  def provision(destination_root, runtime_root, instance_id) do
    with :ok <- provision_input(destination_root, runtime_root, instance_id),
         :ok <- StorePath.private_directory(destination_root),
         :ok <- markers_absent(destination_root),
         document = document(runtime_root, instance_id),
         :ok <- exclusive_write(marker_path(destination_root), Codec.encode!(document) <> "\n") do
      {:ok, marker_path(destination_root)}
    else
      {:error, :exists} -> {:error, :configuration_exists}
      {:error, :failed} -> {:error, :provisioning_failed}
      {:error, :configuration_exists} = error -> error
      _ -> {:error, :invalid_configuration}
    end
  end

  @doc "Requires an intact private marker before loading mutable appliance configuration."
  @spec require_marker(term()) :: :ok | {:error, :recovery_required}
  def require_marker(root) do
    with true <- root_name?(root),
         :ok <- resolve_transition(root),
         {:ok, _document} <- read(root) do
      :ok
    else
      _ -> {:error, :recovery_required}
    end
  end

  @doc "Admits prepared or initialized storage before the service is started."
  @spec admit(term(), term(), term()) :: :ok | {:error, :recovery_required}
  def admit(root, instance_id, data_directory) do
    with :ok <- require_marker(root),
         true <- Codec.id?(instance_id),
         true <- is_binary(data_directory),
         {:ok, document} <- read(root),
         :ok <- validate(document, instance_id, data_directory),
         :ok <- database_state(document["state"], data_directory) do
      :ok
    else
      _ -> {:error, :recovery_required}
    end
  end

  @doc false
  @spec initialized?(term(), term(), term()) :: boolean()
  def initialized?(root, instance_id, data_directory) do
    with :ok <- admit(root, instance_id, data_directory),
         {:ok, %{"state" => "initialized"}} <- read(root),
         do: true,
         else: (_ -> false)
  end

  @doc "Advances a prepared marker after SQLite has opened and passed its checks."
  @spec mark_initialized(term(), term(), term()) :: :ok | {:error, :recovery_required}
  def mark_initialized(root, instance_id, data_directory),
    do: mark_initialized(root, instance_id, data_directory, &exclusive_write/2)

  @doc false
  @spec mark_initialized(term(), term(), term(), (String.t(), binary() -> term())) ::
          :ok | {:error, :recovery_required}
  def mark_initialized(root, instance_id, data_directory, writer)
      when is_function(writer, 2) do
    with :ok <- admit(root, instance_id, data_directory),
         {:ok, document} <- read(root),
         :ok <- advance(root, document, data_directory, writer) do
      :ok
    else
      _ -> {:error, :recovery_required}
    end
  end

  def mark_initialized(_, _, _, _), do: {:error, :recovery_required}

  @doc false
  @spec recovery_failure?(term()) :: boolean()
  def recovery_failure?(reason) when reason in @storage_failures, do: true

  def recovery_failure?(reason) when is_tuple(reason),
    do: reason |> Tuple.to_list() |> Enum.any?(&recovery_failure?/1)

  def recovery_failure?(reason) when is_list(reason), do: Enum.any?(reason, &recovery_failure?/1)
  def recovery_failure?(_), do: false

  defp advance(_root, %{"state" => "initialized"}, _data_directory, _writer), do: :ok

  defp advance(root, %{"state" => "prepared"} = document, data_directory, writer) do
    if initialized_database?(data_directory) do
      next = Path.join(root, @next)
      marker = marker_path(root)
      bytes = document |> Map.put("state", "initialized") |> Codec.encode!()

      case writer.(next, bytes <> "\n") do
        :ok -> rename_marker(next, marker)
        _ -> {:error, :recovery_required}
      end
    else
      {:error, :recovery_required}
    end
  end

  defp advance(_, _, _, _), do: {:error, :recovery_required}

  defp rename_marker(next, marker) do
    case File.rename(next, marker) do
      :ok ->
        :ok

      _ ->
        File.rm(next)
        {:error, :recovery_required}
    end
  end

  defp resolve_transition(root) do
    next = Path.join(root, @next)

    case File.lstat(next) do
      {:error, :enoent} -> :ok
      {:ok, _stat} -> resolve_transition(root, next)
      _ -> {:error, :recovery_required}
    end
  end

  defp resolve_transition(root, next_path) do
    with {:ok, current} <- read(root),
         {:ok, next} <- read_path(next_path),
         true <- transition?(root, current, next),
         true <- initialized_database?(next["data_directory"]) do
      finish_transition(current["state"], next_path, marker_path(root))
    else
      _ -> {:error, :recovery_required}
    end
  end

  defp transition?(root, current, next) do
    current["state"] in @states and next["state"] == "initialized" and
      next["data_directory"] == Path.join(root, "data") and
      validate(next, next["instance_id"], next["data_directory"]) == :ok and
      Map.put(current, "state", "initialized") == next
  end

  defp finish_transition("prepared", next, marker), do: rename_marker(next, marker)

  defp finish_transition("initialized", next, _marker) do
    case File.rm(next) do
      :ok -> :ok
      _ -> {:error, :recovery_required}
    end
  end

  defp finish_transition(_, _, _), do: {:error, :recovery_required}

  defp read(root), do: read_path(marker_path(root))

  defp read_path(path) do
    with {:ok, document} <- FileConfig.read_document(path),
         true <- is_map(document) and map_size(document) == length(@fields),
         true <- Enum.sort(Map.keys(document)) == Enum.sort(@fields) do
      {:ok, document}
    else
      _ -> {:error, :recovery_required}
    end
  end

  defp validate(document, instance_id, data_directory) do
    with "wtr.storage.v1" <- document["schema"],
         state when state in @states <- document["state"],
         ^instance_id <- document["instance_id"],
         ^data_directory <- document["data_directory"],
         "tracker.db" <- document["database"],
         true <- storage_id?(document["storage_id"]) do
      :ok
    else
      _ -> {:error, :recovery_required}
    end
  end

  defp database_state("prepared", directory) do
    case File.lstat(Path.join(directory, "tracker.db")) do
      {:error, :enoent} -> :ok
      {:ok, stat} -> if private_database?(stat), do: :ok, else: {:error, :recovery_required}
      _ -> {:error, :recovery_required}
    end
  end

  defp database_state("initialized", directory) do
    if initialized_database?(directory), do: :ok, else: {:error, :recovery_required}
  end

  defp database_state(_, _), do: {:error, :recovery_required}

  defp initialized_database?(directory) do
    case File.lstat(Path.join(directory, "tracker.db")) do
      {:ok, %{size: size} = stat} when size > 0 -> private_database?(stat)
      _ -> false
    end
  end

  defp private_database?(%{type: :regular, links: 1, mode: mode}), do: (mode &&& 0o077) == 0
  defp private_database?(_), do: false

  defp document(runtime_root, instance_id) do
    %{
      "schema" => "wtr.storage.v1",
      "state" => "prepared",
      "instance_id" => instance_id,
      "storage_id" => Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
      "data_directory" => Path.join(runtime_root, "data"),
      "database" => "tracker.db"
    }
  end

  defp storage_id?(value) when is_binary(value) do
    case Base.decode16(value, case: :lower) do
      {:ok, bytes} -> byte_size(bytes) == 16
      :error -> false
    end
  end

  defp storage_id?(_), do: false

  defp root_name?(path) when is_binary(path) and byte_size(path) in 2..4_096,
    do: Path.type(path) == :absolute and Path.expand(path) == path and Path.dirname(path) != path

  defp root_name?(_), do: false

  defp provision_input(destination_root, runtime_root, instance_id) do
    if root_name?(destination_root) and root_name?(runtime_root) and Codec.id?(instance_id),
      do: :ok,
      else: {:error, :invalid_configuration}
  end

  defp markers_absent(root) do
    if missing?(marker_path(root)) and missing?(Path.join(root, @next)),
      do: :ok,
      else: {:error, :configuration_exists}
  end

  defp marker_path(root), do: Path.join(root, @marker)
  defp missing?(path), do: File.lstat(path) == {:error, :enoent}

  defp exclusive_write(path, bytes) do
    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, file} ->
        result =
          with :ok <- File.chmod(path, 0o600),
               :ok <- IO.binwrite(file, bytes),
               :ok <- :file.sync(file),
               do: :ok,
               else: (_ -> {:error, :failed})

        File.close(file)
        if result != :ok, do: File.rm(path)
        result

      {:error, :eexist} ->
        {:error, :exists}

      _ ->
        {:error, :failed}
    end
  end
end
