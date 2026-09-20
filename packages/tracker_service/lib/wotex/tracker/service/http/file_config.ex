defmodule Wotex.Tracker.Service.HTTP.FileConfig do
  @moduledoc """
  Closed, bounded file configuration shared by service hosts.

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
  @maximum_inactivity_retention_ms 31_536_000_000

  @doc "Loads at most 64 KiB and returns explicit validated HTTP server options."
  @spec load(term()) :: {:ok, keyword()} | {:error, :invalid_configuration}
  def load(path) do
    with {:ok, document} <- read_document(path),
         {:ok, options} <- options(document),
         {:ok, _config} <- ServerConfig.new(options) do
      {:ok, options}
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  @doc "Reads one private JSON document without exposing paths in errors."
  @spec read_document(term()) :: {:ok, term()} | {:error, :invalid_configuration}
  def read_document(path) do
    with :ok <- private_file(path),
         {:ok, bytes} <- bounded_read(path),
         {:ok, document} <- Codec.decode(bytes) do
      {:ok, document}
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
             Enum.all?(
               Map.keys(document),
               &(&1 in (@fields ++ ["tls", "storage_limits", "privacy_policy", "contract"]))
             ),
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
         {:ok, contract} <- contract(document["contract"]),
         {:ok, storage_limits} <- storage_limits(Map.get(document, "storage_limits", %{})),
         {:ok, privacy_policy} <- privacy_policy(Map.get(document, "privacy_policy", %{})) do
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
         contract: contract,
         store_options: storage_limits ++ privacy_policy
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

  defp contract(nil), do: {:ok, :ruuvi_raw_v2}
  defp contract("ruuvi.rawv2"), do: {:ok, :ruuvi_raw_v2}

  defp contract("teltonika.tat140.codec8e"),
    do: {:ok, :teltonika_tat140_codec8e}

  defp contract(_), do: {:error, :invalid_configuration}

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

  @doc false
  def listen(%{"ip" => ip, "port" => port} = listen)
      when map_size(listen) == 2 and is_binary(ip) do
    with {:ok, address} <- :inet.parse_strict_address(String.to_charlist(ip)),
         do: {:ok, address, port}
  end

  def listen(_), do: {:error, :invalid_configuration}

  @doc false
  def exposure("loopback"), do: {:ok, :loopback}
  def exposure("proxy"), do: {:ok, :proxy}
  def exposure("tls"), do: {:ok, :tls}
  def exposure(_), do: {:error, :invalid_configuration}

  @doc false
  def tls(nil), do: {:ok, nil}

  def tls(%{"certfile" => cert, "keyfile" => key} = tls) when map_size(tls) == 2,
    do: {:ok, %{certfile: cert, keyfile: key}}

  def tls(_), do: {:error, :invalid_configuration}

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

  defp privacy_policy(policy) when is_map(policy) and map_size(policy) == 0, do: {:ok, []}

  defp privacy_policy(%{"domain_inactivity_retention_ms" => retention} = policy)
       when map_size(policy) == 1 and is_integer(retention) and
              retention in 60_000..@maximum_inactivity_retention_ms,
       do: {:ok, [domain_inactivity_retention_ms: retention]}

  defp privacy_policy(_), do: {:error, :invalid_configuration}
end
