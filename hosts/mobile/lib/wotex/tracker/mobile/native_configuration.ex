defmodule Wotex.Tracker.Mobile.NativeConfiguration do
  @moduledoc """
  Stores the non-secret service origin selected by the native application.

  The document is deliberately smaller than the runtime host configuration:
  capabilities, signing secrets, credentials and notification tokens are never
  persisted here. The containing directory and file must already be private.
  """

  import Bitwise
  alias Wotex.Tracker.UI.Remote

  @schema "wtr.mobile-native-configuration.v1"
  @filename "native-configuration.json"
  @maximum_bytes 4_096
  @fields ~w(schema remote_origin)

  @enforce_keys [:remote_origin]
  defstruct @enforce_keys

  @type t :: %__MODULE__{remote_origin: String.t()}

  @doc "Admits one exact canonical HTTPS service origin."
  @spec new(term()) :: {:ok, t()} | {:error, :invalid_configuration}
  def new(origin) when is_binary(origin) and byte_size(origin) in 1..2_048 do
    with true <- String.valid?(origin),
         %URI{host: host} when is_binary(host) <- URI.parse(origin),
         true <- String.downcase(host) == host,
         {:ok, %Remote{origin: canonical}} <- Remote.new(origin: origin),
         true <- canonical == origin do
      {:ok, %__MODULE__{remote_origin: canonical}}
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  def new(_), do: {:error, :invalid_configuration}

  @doc "Loads the private native configuration or reports an honest first run."
  @spec load(term()) :: {:ok, t()} | :missing | {:error, :invalid_configuration}
  def load(directory) do
    with {:ok, path} <- path(directory),
         :ok <- private_directory(directory) do
      case File.lstat(path) do
        {:error, :enoent} -> :missing
        {:ok, stat} -> decode_file(path, stat)
        _ -> {:error, :invalid_configuration}
      end
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  @doc "Atomically replaces the private non-secret configuration document."
  @spec save(term(), t()) :: :ok | {:error, :configuration_unavailable}
  def save(directory, %__MODULE__{} = config) do
    with {:ok, path} <- path(directory),
         :ok <- private_directory(directory),
         :ok <- replaceable(path),
         {:ok, admitted} <- new(config.remote_origin),
         {:ok, bytes} <- encode(admitted),
         :ok <- atomic_replace(path, bytes) do
      :ok
    else
      _ -> {:error, :configuration_unavailable}
    end
  end

  def save(_, _), do: {:error, :configuration_unavailable}

  defp decode_file(path, %{type: :regular, links: 1, size: size, mode: mode})
       when size in 1..@maximum_bytes and (mode &&& 0o777) == 0o600 do
    with {:ok, bytes} <- File.open(path, [:read, :binary], &IO.binread(&1, @maximum_bytes + 1)),
         true <- is_binary(bytes) and byte_size(bytes) <= @maximum_bytes,
         {:ok, document} <- Wotex.JSON.decode(bytes, json_limits()),
         {:ok, config} <- decode(document) do
      {:ok, config}
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  defp decode_file(_, _), do: {:error, :invalid_configuration}

  defp decode(document) when is_map(document) and map_size(document) == 2 do
    with true <- Enum.sort(Map.keys(document)) == Enum.sort(@fields),
         @schema <- document["schema"],
         {:ok, config} <- new(document["remote_origin"]) do
      {:ok, config}
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  defp decode(_), do: {:error, :invalid_configuration}

  defp encode(config) do
    Wotex.JSON.encode(
      %{"schema" => @schema, "remote_origin" => config.remote_origin},
      Keyword.put(json_limits(), :max_bytes, @maximum_bytes)
    )
  end

  defp json_limits do
    [
      max_bytes: @maximum_bytes,
      max_depth: 4,
      max_nodes: 8,
      max_string_bytes: 2_048,
      max_collection_size: 2
    ]
  end

  defp path(directory)
       when is_binary(directory) and byte_size(directory) in 1..4_096 do
    if Path.type(directory) == :absolute and Path.expand(directory) == directory,
      do: {:ok, Path.join(directory, @filename)},
      else: {:error, :invalid_configuration}
  end

  defp path(_), do: {:error, :invalid_configuration}

  defp private_directory(directory) do
    with true <- real_directories(directory),
         {:ok, %{type: :directory, mode: mode}} <- File.lstat(directory),
         true <- (mode &&& 0o777) == 0o700 do
      :ok
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  defp real_directories(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        parent = Path.dirname(path)
        parent == path or real_directories(parent)

      _ ->
        false
    end
  end

  defp replaceable(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular, links: 1, mode: mode}} when (mode &&& 0o777) == 0o600 -> :ok
      {:error, :enoent} -> :ok
      _ -> {:error, :invalid_configuration}
    end
  end

  defp atomic_replace(path, bytes) do
    temporary = path <> "." <> random_suffix() <> ".tmp"

    result =
      case write_temporary(temporary, bytes) do
        :ok -> File.rename(temporary, path)
        {:error, _} = error -> error
      end

    if result != :ok, do: File.rm(temporary)
    result
  end

  defp write_temporary(path, bytes) do
    case File.open(path, [:write, :binary, :exclusive], &persist(&1, path, bytes)) do
      {:ok, :ok} -> :ok
      _ -> {:error, :configuration_unavailable}
    end
  end

  defp persist(file, path, bytes) do
    with :ok <- File.chmod(path, 0o600),
         :ok <- IO.binwrite(file, bytes) do
      :file.sync(file)
    end
  end

  defp random_suffix,
    do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
end
