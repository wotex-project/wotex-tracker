defmodule Wotex.Tracker.Nerves.Config do
  @moduledoc """
  Appliance policy around the shared private service document.

  Configuration, storage and TLS material must have been provisioned under a
  private writable root before the appliance starts. Nothing in the firmware
  contains a credential or creates one on boot.
  """

  import Bitwise
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
