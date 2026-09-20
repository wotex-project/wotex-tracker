defmodule Wotex.Tracker.Service.HostProvisioning do
  @moduledoc """
  Creates one private host configuration without exposing its token.

  The destination is where files are written. The runtime root is the absolute
  path those files will have when the host starts, so an offline appliance image
  can be staged at a different mount point. The caller supplies explicit expiry
  time; this module reads no clock and never starts a listener.

  Provisioning is create-only. Existing configuration, token or data paths are
  never replaced. A failed attempt removes only paths created by that attempt.
  """

  import Bitwise
  alias Wotex.Tracker.Service.{Codec, Credentials, StorePath}
  alias Wotex.Tracker.Service.HTTP.FileConfig

  @grants ~w(read raw ingest enroll admin interact)
  @required ~w(destination_root runtime_root instance_id scope ip port expires_at)a
  @tls_required @required ++ ~w(public_origin certfile keyfile)a

  @type paths :: %{
          config: String.t(),
          token_file: String.t(),
          data_directory: String.t(),
          runtime_config: String.t(),
          runtime_data_directory: String.t()
        }

  @doc "Creates a private configuration, bearer-token file and empty data directory."
  @spec initialize(term()) ::
          {:ok, paths()}
          | {:error,
             :invalid_configuration
             | :private_directory_required
             | :configuration_exists
             | :provisioning_failed}
  def initialize(input), do: initialize(input, &exclusive_write/2)

  @doc "Creates a private direct-TLS configuration with caller-owned certificate paths."
  @spec initialize_tls(term()) ::
          {:ok, paths()}
          | {:error,
             :invalid_configuration
             | :private_directory_required
             | :configuration_exists
             | :provisioning_failed}
  def initialize_tls(input), do: initialize_tls(input, &exclusive_write/2)

  @doc false
  @spec initialize(term(), (String.t(), binary() -> :ok | {:error, atom()})) ::
          {:ok, paths()} | {:error, atom()}
  def initialize(input, writer)
      when is_map(input) and map_size(input) == length(@required) and is_function(writer, 2) do
    with true <- Enum.sort(Map.keys(input)) == Enum.sort(@required),
         {:ok, context} <- validate(input, :loopback) do
      provision(Map.put(context, :writer, writer))
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  def initialize(_, _), do: {:error, :invalid_configuration}

  @doc false
  @spec initialize_tls(term(), (String.t(), binary() -> :ok | {:error, atom()})) ::
          {:ok, paths()} | {:error, atom()}
  def initialize_tls(input, writer)
      when is_map(input) and map_size(input) == length(@tls_required) and is_function(writer, 2) do
    with true <- Enum.sort(Map.keys(input)) == Enum.sort(@tls_required),
         {:ok, context} <- validate(input, :tls) do
      provision(Map.put(context, :writer, writer))
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  def initialize_tls(_, _), do: {:error, :invalid_configuration}

  defp validate(input, exposure) do
    with true <- private_root_name?(input.destination_root),
         true <- private_root_name?(input.runtime_root),
         true <- Codec.id?(input.instance_id) and Codec.id?(input.scope),
         true <- address?(input.ip, exposure),
         true <- is_integer(input.port) and input.port in 1..65_535,
         true <- Codec.time?(input.expires_at),
         {:ok, endpoint} <- endpoint(input, exposure) do
      {:ok,
       Map.merge(
         %{
           destination_root: input.destination_root,
           runtime_root: input.runtime_root,
           instance_id: input.instance_id,
           scope: input.scope,
           ip: input.ip,
           port: input.port,
           expires_at: input.expires_at,
           exposure: exposure,
           paths: paths(input.destination_root, input.runtime_root)
         },
         endpoint
       )}
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  defp address?(ip, :loopback), do: ip in ["127.0.0.1", "::1"]

  defp address?(ip, :tls) when is_binary(ip) do
    match?({:ok, _}, :inet.parse_strict_address(String.to_charlist(ip)))
  end

  defp address?(_, _), do: false

  defp endpoint(_input, :loopback), do: {:ok, %{public_origin: "listener", tls: nil}}

  defp endpoint(input, :tls) do
    if https_origin?(input.public_origin) and input.certfile != input.keyfile and
         under_root?(input.certfile, input.runtime_root) and
         under_root?(input.keyfile, input.runtime_root) do
      {:ok,
       %{
         public_origin: input.public_origin,
         tls: %{"certfile" => input.certfile, "keyfile" => input.keyfile}
       }}
    else
      {:error, :invalid_configuration}
    end
  end

  defp https_origin?(value) when is_binary(value) and byte_size(value) in 1..2_048 do
    case URI.new(value) do
      {:ok,
       %URI{
         scheme: "https",
         userinfo: nil,
         query: nil,
         fragment: nil,
         path: path,
         host: host,
         port: port
       }}
      when path in [nil, "", "/"] and is_binary(host) and host != "" and port in 1..65_535 ->
        true

      _ ->
        false
    end
  end

  defp https_origin?(_), do: false

  defp under_root?(path, root) when is_binary(path),
    do:
      private_root_name?(path) and Path.expand(path) == path and
        String.starts_with?(path, root <> "/")

  defp under_root?(_, _), do: false

  defp private_root_name?(path) when is_binary(path) and byte_size(path) in 2..4_096,
    do: Path.type(path) == :absolute and Path.expand(path) == path and Path.dirname(path) != path

  defp private_root_name?(_), do: false

  defp paths(destination, runtime) do
    %{
      config: Path.join(destination, "config.json"),
      token_file: Path.join(destination, "operator.token"),
      data_directory: Path.join(destination, "data"),
      runtime_config: Path.join(runtime, "config.json"),
      runtime_data_directory: Path.join(runtime, "data")
    }
  end

  defp provision(context) do
    with {:ok, root_created?} <- ensure_root(context.destination_root) do
      result = create(context)
      if match?({:error, _}, result) and root_created?, do: File.rmdir(context.destination_root)
      result
    end
  end

  defp ensure_root(root) do
    case File.lstat(root) do
      {:error, :enoent} -> create_root(root)
      {:ok, _} -> existing_root(root)
      _ -> {:error, :private_directory_required}
    end
  end

  defp create_root(root) do
    case File.mkdir(root) do
      :ok ->
        with :ok <- File.chmod(root, 0o700),
             :ok <- exact_private_root(root) do
          {:ok, true}
        else
          _ ->
            File.rmdir(root)
            {:error, :private_directory_required}
        end

      _ ->
        {:error, :private_directory_required}
    end
  end

  defp existing_root(root) do
    case exact_private_root(root) do
      :ok -> {:ok, false}
      _ -> {:error, :private_directory_required}
    end
  end

  defp exact_private_root(root) do
    with :ok <- StorePath.private_directory(root),
         {:ok, %{type: :directory, mode: mode}} <- File.lstat(root),
         true <- (mode &&& 0o777) == 0o700 do
      :ok
    else
      _ -> {:error, :private_directory_required}
    end
  end

  defp create(context) do
    case targets_absent(context.paths) do
      :ok -> create_absent(context)
      {:error, _} = error -> error
    end
  end

  defp create_absent(context) do
    with :ok <- create_data_directory(context.paths.data_directory) do
      create_after_data(context)
    end
  end

  defp create_after_data(context) do
    token = Credentials.generate_token()

    with {:ok, digest} <- Credentials.token_digest(token),
         :ok <- write(context, context.paths.token_file, token <> "\n") do
      create_after_token(context, digest)
    else
      {:error, reason} ->
        File.rmdir(context.paths.data_directory)
        {:error, reason}
    end
  end

  defp create_after_token(context, digest) do
    document = document(context, digest)

    case write(context, context.paths.config, Codec.encode!(document) <> "\n") do
      :ok ->
        validate_created(context, document)

      {:error, reason} ->
        _ = [File.rm(context.paths.token_file), File.rmdir(context.paths.data_directory)]
        {:error, reason}
    end
  end

  defp validate_created(context, expected) do
    case {FileConfig.read_document(context.paths.config), FileConfig.load(context.paths.config)} do
      {{:ok, ^expected}, {:ok, options}} ->
        if options[:directory] == context.paths.runtime_data_directory and
             options[:exposure] == context.exposure,
           do: {:ok, context.paths},
           else: discard_created(context)

      _ ->
        discard_created(context)
    end
  end

  defp discard_created(context) do
    _ =
      [
        File.rm(context.paths.config),
        File.rm(context.paths.token_file),
        File.rmdir(context.paths.data_directory)
      ]

    {:error, :provisioning_failed}
  end

  defp targets_absent(paths) do
    if Enum.all?([paths.config, paths.token_file, paths.data_directory], &missing?/1),
      do: :ok,
      else: {:error, :configuration_exists}
  end

  defp missing?(path), do: File.lstat(path) == {:error, :enoent}

  defp create_data_directory(path) do
    case File.mkdir(path) do
      :ok ->
        with :ok <- File.chmod(path, 0o700),
             :ok <- StorePath.private_directory(path) do
          :ok
        else
          _ ->
            File.rmdir(path)
            {:error, :provisioning_failed}
        end

      {:error, :eexist} ->
        {:error, :configuration_exists}

      _ ->
        {:error, :provisioning_failed}
    end
  end

  defp document(context, digest) do
    document = %{
      "schema" => "wtr.host.v1",
      "instance_id" => context.instance_id,
      "secret_key" => Base.encode64(:crypto.strong_rand_bytes(32)),
      "data_directory" => context.paths.runtime_data_directory,
      "listen" => %{"ip" => context.ip, "port" => context.port},
      "exposure" => Atom.to_string(context.exposure),
      "public_origin" => context.public_origin,
      "credentials" => [
        %{
          "id" => "operator",
          "principal" => "operator",
          "token_sha256" => digest,
          "grants" => %{context.scope => @grants},
          "expires_at" => context.expires_at
        }
      ]
    }

    if context.tls, do: Map.put(document, "tls", context.tls), else: document
  end

  defp write(context, path, bytes) do
    case context.writer.(path, bytes) do
      :ok ->
        :ok

      {:error, reason} when reason in [:configuration_exists, :provisioning_failed] ->
        {:error, reason}

      _ ->
        {:error, :provisioning_failed}
    end
  end

  defp exclusive_write(path, bytes) do
    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, file} ->
        result =
          with :ok <- File.chmod(path, 0o600),
               :ok <- IO.binwrite(file, bytes),
               :ok <- :file.sync(file) do
            :ok
          else
            _ -> {:error, :provisioning_failed}
          end

        File.close(file)
        if match?({:error, _}, result), do: File.rm(path)
        result

      {:error, :eexist} ->
        {:error, :configuration_exists}

      _ ->
        {:error, :provisioning_failed}
    end
  end
end
