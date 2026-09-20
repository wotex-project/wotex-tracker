defmodule Wotex.Tracker.Nerves.TLSProvisioning do
  @moduledoc """
  Copies operator-supplied TLS material into a private appliance tree.

  Sources and destinations must be singly linked 0600 regular files under
  private, symlink-free directories. The operation accepts a bounded PEM
  certificate chain and one unencrypted supported private key, writes fixed
  create-only target names, syncs them, and never returns their contents.
  """

  import Bitwise
  alias Wotex.Tracker.Service.StorePath

  @cert_name "tls-cert.pem"
  @key_name "tls-key.pem"
  @maximum_bytes 65_536
  @key_types [:RSAPrivateKey, :ECPrivateKey, :PrivateKeyInfo]
  @rsa_oid {1, 2, 840, 113_549, 1, 1, 1}
  @ec_oid {1, 2, 840, 10_045, 2, 1}

  @type paths :: %{
          certfile: String.t(),
          keyfile: String.t(),
          runtime_certfile: String.t(),
          runtime_keyfile: String.t()
        }

  @doc "Stages one bounded PEM certificate chain and unencrypted private key."
  @spec provision(term(), term(), term(), term()) ::
          {:ok, paths()}
          | {:error, :invalid_configuration | :configuration_exists | :provisioning_failed}
  def provision(root, runtime_root, cert_source, key_source),
    do: provision(root, runtime_root, cert_source, key_source, &exclusive_write/2)

  @doc false
  @spec provision(term(), term(), term(), term(), (String.t(), binary() -> term())) ::
          {:ok, paths()} | {:error, atom()}
  def provision(root, runtime_root, cert_source, key_source, writer)
      when is_binary(root) and is_binary(runtime_root) and is_binary(cert_source) and
             is_binary(key_source) and is_function(writer, 2) do
    paths = paths(root, runtime_root)

    with true <- root_name?(runtime_root),
         :ok <- StorePath.private_directory(root),
         true <- cert_source != key_source,
         {:ok, cert} <- read_source(cert_source),
         {:ok, key} <- read_source(key_source),
         true <- certificate_chain?(cert),
         true <- private_key?(key),
         true <- matching_pair?(cert, key),
         :ok <- targets_absent(paths),
         :ok <- provision_targets(writer, paths, cert, key) do
      {:ok, paths}
    else
      false -> {:error, :invalid_configuration}
      {:error, _} = error -> error
    end
  end

  def provision(_, _, _, _, _), do: {:error, :invalid_configuration}

  defp paths(root, runtime_root) do
    %{
      certfile: Path.join(root, @cert_name),
      keyfile: Path.join(root, @key_name),
      runtime_certfile: Path.join(runtime_root, @cert_name),
      runtime_keyfile: Path.join(runtime_root, @key_name)
    }
  end

  defp read_source(path) do
    with true <- root_name?(path),
         :ok <- StorePath.private_directory(Path.dirname(path)),
         {:ok, %{type: :regular, links: 1, size: size, mode: mode}} <- File.lstat(path),
         true <- size in 1..@maximum_bytes and (mode &&& 0o777) == 0o600,
         {:ok, bytes} when is_binary(bytes) and byte_size(bytes) in 1..@maximum_bytes <-
           File.open(path, [:read, :binary], fn file -> IO.binread(file, @maximum_bytes + 1) end) do
      {:ok, bytes}
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  defp certificate_chain?(bytes) do
    case :public_key.pem_decode(bytes) do
      entries when length(entries) in 1..8 ->
        Enum.all?(entries, &(elem(&1, 0) == :Certificate and decodes?(&1)))

      _ ->
        false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp private_key?(bytes) do
    case :public_key.pem_decode(bytes) do
      [{type, _, :not_encrypted} = entry] when type in @key_types -> decodes?(entry)
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp decodes?(entry) do
    _ = :public_key.pem_entry_decode(entry)
    true
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp matching_pair?(certificate_pem, key_pem) do
    [leaf | _] = :public_key.pem_decode(certificate_pem)
    [key_entry] = :public_key.pem_decode(key_pem)
    certificate = leaf |> elem(1) |> :public_key.pkix_decode_cert(:otp)
    private_key = :public_key.pem_entry_decode(key_entry)
    public_key = certificate_public_key(certificate)
    message = "wotex-tls-provisioning-pair-check"
    signature = :public_key.sign(message, :sha256, private_key)
    :public_key.verify(message, :sha256, signature, public_key)
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp certificate_public_key(certificate) do
    tbs_certificate = elem(certificate, 1)
    subject_public_key_info = elem(tbs_certificate, 7)
    algorithm = elem(subject_public_key_info, 1)
    public_key = elem(subject_public_key_info, 2)

    case elem(algorithm, 1) do
      @rsa_oid -> public_key
      @ec_oid -> {public_key, elem(algorithm, 2)}
      _ -> raise ArgumentError, "unsupported certificate key"
    end
  end

  defp targets_absent(paths) do
    if Enum.all?([paths.certfile, paths.keyfile], &(File.lstat(&1) == {:error, :enoent})),
      do: :ok,
      else: {:error, :configuration_exists}
  end

  defp provision_targets(writer, paths, cert, key) do
    case write_and_check(writer, paths.certfile, cert) do
      :ok ->
        provision_key(writer, paths, key)

      {:error, :configuration_exists} = error ->
        error

      {:error, _} = error ->
        File.rm(paths.certfile)
        error
    end
  end

  defp provision_key(writer, paths, key) do
    case write_and_check(writer, paths.keyfile, key) do
      :ok ->
        :ok

      {:error, :configuration_exists} = error ->
        File.rm(paths.certfile)
        error

      {:error, _} = error ->
        _ = [File.rm(paths.certfile), File.rm(paths.keyfile)]
        error
    end
  end

  defp write_and_check(writer, path, bytes) do
    with :ok <- write(writer, path, bytes),
         {:ok, %{type: :regular, links: 1, size: size, mode: mode}} <- File.lstat(path),
         true <- size == byte_size(bytes) and (mode &&& 0o777) == 0o600,
         {:ok, ^bytes} <- File.read(path) do
      :ok
    else
      {:error, :configuration_exists} = error -> error
      _ -> {:error, :provisioning_failed}
    end
  end

  defp write(writer, path, bytes) do
    case writer.(path, bytes) do
      :ok -> :ok
      {:error, :configuration_exists} -> {:error, :configuration_exists}
      _ -> {:error, :provisioning_failed}
    end
  end

  defp exclusive_write(path, bytes) do
    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, file} ->
        result =
          with :ok <- File.chmod(path, 0o600),
               :ok <- IO.binwrite(file, bytes),
               :ok <- :file.sync(file),
               do: :ok,
               else: (_ -> {:error, :provisioning_failed})

        File.close(file)
        if result != :ok, do: File.rm(path)
        result

      {:error, :eexist} ->
        {:error, :configuration_exists}

      _ ->
        {:error, :provisioning_failed}
    end
  end

  defp root_name?(path) when is_binary(path) and byte_size(path) in 2..4_096,
    do: Path.type(path) == :absolute and Path.expand(path) == path and Path.dirname(path) != path

  defp root_name?(_), do: false
end
