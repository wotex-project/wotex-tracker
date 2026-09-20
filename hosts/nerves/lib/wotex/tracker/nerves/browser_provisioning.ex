defmodule Wotex.Tracker.Nerves.BrowserProvisioning do
  @moduledoc """
  Creates one private loopback configuration for the optional kiosk browser.

  The operation is create-only, generates its own session-signing secret and
  returns only the file path. It has no Phoenix or LiveView dependency, so the
  source provisioner remains usable from the headless host profile.
  """

  alias Wotex.Tracker.Service.{Codec, StorePath}
  alias Wotex.Tracker.Service.HTTP.FileConfig

  @fields ~w(schema listen exposure public_origin secret_key_base)

  @doc "Creates an exclusive 0600 loopback browser document under a private root."
  @spec provision(term(), term()) ::
          {:ok, String.t()}
          | {:error, :invalid_configuration | :configuration_exists | :provisioning_failed}
  def provision(root, port), do: provision(root, port, &exclusive_write/2)

  @doc false
  @spec provision(term(), term(), (String.t(), binary() -> term())) ::
          {:ok, String.t()} | {:error, atom()}
  def provision(root, port, writer)
      when is_binary(root) and is_integer(port) and port in 1..65_535 and
             is_function(writer, 2) do
    path = Path.join(root, "browser.json")

    with :ok <- StorePath.private_directory(root),
         true <- File.lstat(path) == {:error, :enoent},
         document = document(port),
         :ok <- write(writer, path, Codec.encode!(document) <> "\n"),
         :ok <- validate_created(path, document) do
      {:ok, path}
    else
      false -> {:error, :configuration_exists}
      {:error, _} = error -> error
    end
  end

  def provision(_, _, _), do: {:error, :invalid_configuration}

  defp document(port) do
    %{
      "schema" => "wtr.browser.v1",
      "listen" => %{"ip" => "127.0.0.1", "port" => port},
      "exposure" => "loopback",
      "public_origin" => "http://127.0.0.1:#{port}",
      "secret_key_base" => Base.encode64(:crypto.strong_rand_bytes(64))
    }
  end

  defp validate_created(path, expected) do
    case FileConfig.read_document(path) do
      {:ok, document}
      when is_map(document) and map_size(document) == length(@fields) and
             document == expected ->
        :ok

      _ ->
        File.rm(path)
        {:error, :provisioning_failed}
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
end
