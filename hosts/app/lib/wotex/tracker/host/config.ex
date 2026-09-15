defmodule Wotex.Tracker.Host.Config do
  @moduledoc """
  Closed, bounded file configuration for the standalone service host.

  Configuration is a regular, singly linked 0600 file in a private directory.
  Its absolute path and all ancestors must be free of symlinks. This assumes
  the same OS account is trusted; it is not protection from hostile same-user
  filesystem replacement. Credentials are hashed entries plus an instance key.
  Invalid configuration returns one fixed error without secret or path content.
  """
  import Bitwise
  alias Wotex.Tracker.Service.{Codec, Credentials}
  alias Wotex.Tracker.Service.HTTP.Config, as: ServerConfig

  @fields ~w(schema instance_id secret_key data_directory listen exposure public_origin credentials)
  @storage_limits %{
    "max_rows" => {:max_rows, 100_000},
    "max_pages" => {:max_pages, 262_144},
    "busy_timeout" => {:busy_timeout, 1000},
    "timeout" => {:timeout, 5000}
  }

  @doc "Loads at most 64 KiB and returns explicit validated HTTP server options."
  @spec load(term()) :: {:ok, keyword()} | {:error, :invalid_configuration}
  def load(path) do
    with :ok <- private_file(path),
         {:ok, bytes} <- bounded_read(path),
         {:ok, document} <- Codec.decode(bytes),
         {:ok, options} <- options(document),
         {:ok, _config} <- ServerConfig.new(options) do
      {:ok, options}
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  defp private_file(path) when is_binary(path) do
    with true <- Path.type(path) == :absolute,
         :ok <- real_directories(Path.dirname(path)),
         {:ok, parent} <- File.lstat(Path.dirname(path)),
         true <- (parent.mode &&& 0o777) == 0o700,
         {:ok, %{type: :regular, links: 1, size: size, mode: mode}} <- File.lstat(path),
         true <- size in 1..65_536 and (mode &&& 0o777) == 0o600 do
      :ok
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  defp private_file(_), do: {:error, :invalid_configuration}

  defp real_directories(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        parent = Path.dirname(path)
        if parent == path, do: :ok, else: real_directories(parent)

      _ ->
        {:error, :invalid_configuration}
    end
  end

  defp bounded_read(path) do
    case File.open(path, [:read, :binary], fn file -> IO.binread(file, 65_537) end) do
      {:ok, bytes} when is_binary(bytes) and byte_size(bytes) <= 65_536 -> {:ok, bytes}
      _ -> {:error, :invalid_configuration}
    end
  end

  defp options(document) when is_map(document) do
    with true <-
           Enum.all?(@fields, &Map.has_key?(document, &1)) and
             Enum.all?(Map.keys(document), &(&1 in (@fields ++ ["tls", "storage_limits"]))),
         "wtr.host.v1" <- document["schema"],
         {:ok, secret} <- key(document["secret_key"]),
         {:ok, entries} <- entries(document["credentials"]),
         {:ok, credentials} <-
           Credentials.new(%{
             instance_id: document["instance_id"],
             secret_key: secret,
             entries: entries
           }),
         {:ok, ip, port} <- listen(document["listen"]),
         {:ok, exposure} <- exposure(document["exposure"]),
         {:ok, tls} <- tls(document["tls"]),
         {:ok, storage_limits} <- storage_limits(Map.get(document, "storage_limits", %{})) do
      origin =
        if document["public_origin"] == "listener", do: :listener, else: document["public_origin"]

      {:ok,
       [
         directory: document["data_directory"],
         credentials: credentials,
         ip: ip,
         port: port,
         exposure: exposure,
         public_origin: origin,
         tls: tls,
         store_options: storage_limits
       ]}
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  defp options(_), do: {:error, :invalid_configuration}

  defp key(value) when is_binary(value) do
    with {:ok, bytes} <- Base.decode64(value),
         true <- byte_size(bytes) == 32 and Base.encode64(bytes) == value,
         do: {:ok, bytes},
         else: (_ -> {:error, :invalid_configuration})
  end

  defp key(_), do: {:error, :invalid_configuration}

  defp entries(values) when is_list(values) and length(values) in 1..32 do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, entries} ->
      case entry(value) do
        {:ok, entry} -> {:cont, {:ok, [entry | entries]}}
        error -> {:halt, error}
      end
    end)
  end

  defp entries(_), do: {:error, :invalid_configuration}

  defp entry(
         %{
           "id" => id,
           "principal" => principal,
           "token_sha256" => digest,
           "grants" => grants,
           "expires_at" => expiry
         } = entry
       )
       when map_size(entry) == 5 and is_binary(digest) do
    case Base.decode16(digest, case: :lower) do
      {:ok, bytes} when byte_size(bytes) == 32 ->
        {:ok,
         %{id: id, principal: principal, token_sha256: digest, grants: grants, expires_at: expiry}}

      _ ->
        {:error, :invalid_configuration}
    end
  end

  defp entry(_), do: {:error, :invalid_configuration}

  defp listen(%{"ip" => ip, "port" => port} = listen)
       when map_size(listen) == 2 and is_binary(ip) do
    with {:ok, address} <- :inet.parse_strict_address(String.to_charlist(ip)),
         do: {:ok, address, port}
  end

  defp listen(_), do: {:error, :invalid_configuration}

  defp exposure("loopback"), do: {:ok, :loopback}
  defp exposure("proxy"), do: {:ok, :proxy}
  defp exposure("tls"), do: {:ok, :tls}
  defp exposure(_), do: {:error, :invalid_configuration}

  defp tls(nil), do: {:ok, nil}

  defp tls(%{"certfile" => cert, "keyfile" => key} = tls) when map_size(tls) == 2,
    do: {:ok, %{certfile: cert, keyfile: key}}

  defp tls(_), do: {:error, :invalid_configuration}

  defp storage_limits(limits) when is_map(limits) and map_size(limits) <= 4 do
    Enum.reduce_while(limits, {:ok, []}, fn {name, value}, {:ok, options} ->
      case @storage_limits[name] do
        {key, maximum} when is_integer(value) and value > 0 and value <= maximum ->
          {:cont, {:ok, [{key, value} | options]}}

        _ ->
          {:halt, {:error, :invalid_configuration}}
      end
    end)
  end

  defp storage_limits(_), do: {:error, :invalid_configuration}
end
