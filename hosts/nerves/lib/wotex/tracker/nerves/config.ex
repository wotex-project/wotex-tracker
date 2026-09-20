defmodule Wotex.Tracker.Nerves.Config do
  @moduledoc """
  Appliance policy around the shared private service document.

  Configuration, storage and TLS material must have been provisioned under a
  private writable root before the appliance starts. Nothing in the firmware
  contains a credential or creates one on boot.
  """

  import Bitwise
  alias Wotex.Tracker.Service.{APNsHostConfig, Cellular.HostConfig}
  alias Wotex.Tracker.Service.HTTP.Config, as: ServerConfig
  alias Wotex.Tracker.Service.HTTP.FileConfig
  alias Wotex.Tracker.Service.StorePath

  @spec load(term(), term()) :: {:ok, keyword()} | {:error, :invalid_configuration}
  def load(path, root) do
    with true <- private_root?(root),
         true <- path == Path.join(root, "config.json"),
         {:ok, options} <- FileConfig.load(path),
         true <- options[:exposure] in [:loopback, :tls],
         true <- under_root?(options[:directory], root),
         :ok <- StorePath.private_directory(options[:directory]),
         true <- private_tls?(options[:tls], root) do
      {:ok, options}
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  @doc "Loads an optional private cellular document from the fixed appliance root."
  @spec load_cellular(term(), term(), keyword()) ::
          {:ok, HostConfig.t() | nil} | {:error, :invalid_configuration}
  def load_cellular(nil, _root, _service_options), do: {:ok, nil}

  def load_cellular(path, root, service_options)
      when is_binary(root) and is_list(service_options) do
    with true <- private_root?(root),
         true <- path == Path.join(root, "cellular.json"),
         {:ok, document} <- FileConfig.read_document(path),
         credentials when not is_nil(credentials) <- service_options[:credentials],
         contract when not is_nil(contract) <- service_options[:contract] do
      HostConfig.new(document, credentials, contract)
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  def load_cellular(_, _, _), do: {:error, :invalid_configuration}

  @doc "Loads an optional private APNs document from the fixed appliance root."
  @spec load_apns(term(), term(), keyword()) ::
          {:ok, APNsHostConfig.t() | nil} | {:error, :invalid_configuration}
  def load_apns(nil, _root, _service_options), do: {:ok, nil}

  def load_apns(path, root, service_options)
      when is_binary(root) and is_list(service_options) do
    with true <- private_root?(root),
         true <- path == Path.join(root, "apns.json"),
         {:ok, document} <- FileConfig.read_document(path),
         {:ok, config} <- APNsHostConfig.new(document),
         dispatcher = APNsHostConfig.dispatcher_options(config),
         {:ok, _} <-
           ServerConfig.new(Keyword.put(service_options, :notification_dispatcher, dispatcher)) do
      {:ok, config}
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  def load_apns(_, _, _), do: {:error, :invalid_configuration}

  defp private_root?(root) when is_binary(root),
    do: StorePath.private_directory(root) == :ok

  defp private_root?(_), do: false

  defp under_root?(path, root) when is_binary(path) do
    Path.type(path) == :absolute and Path.expand(path) == path and
      String.starts_with?(path, root <> "/")
  end

  defp under_root?(_, _), do: false

  defp private_tls?(nil, _), do: true

  defp private_tls?(%{certfile: cert, keyfile: key}, root),
    do: private_material?(cert, root) and private_material?(key, root)

  defp private_material?(path, root) do
    under_root?(path, root) and
      StorePath.private_directory(Path.dirname(path)) == :ok and
      case File.lstat(path) do
        {:ok, %{type: :regular, links: 1, size: size, mode: mode}} ->
          size in 1..65_536 and (mode &&& 0o777) == 0o600

        _ ->
          false
      end
  end
end
