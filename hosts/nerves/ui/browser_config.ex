defmodule Wotex.Tracker.Nerves.BrowserConfig do
  @moduledoc """
  Loads the Pi control panel's private loopback configuration.

  `load/3` accepts only `browser.json` under the writable private root. It
  checks the closed schema, file and directory policy, listener and matching
  origin, and session-signing secret before returning a listener configuration.
  Inspection includes only the address, port, and origin, never the secret.
  """

  @derive {Inspect, only: [:ip, :port, :public_origin]}
  @enforce_keys [:ip, :port, :public_origin, :secret_key_base]
  defstruct @enforce_keys

  alias Wotex.Tracker.Service.HTTP.Config, as: ServerConfig
  alias Wotex.Tracker.Service.HTTP.FileConfig
  alias Wotex.Tracker.Service.StorePath

  @spec load(term(), term(), keyword()) :: {:ok, %__MODULE__{}} | {:error, :invalid_configuration}
  def load(path, root, service_options) do
    with :ok <- StorePath.private_directory(root),
         true <- path == Path.join(root, "browser.json"),
         {:ok,
          %{
            "schema" => "wtr.browser.v1",
            "listen" => listen,
            "exposure" => "loopback",
            "public_origin" => origin,
            "secret_key_base" => secret
          } = document} <- FileConfig.read_document(path),
         true <- map_size(document) == 5,
         true <- is_binary(secret) and byte_size(secret) in 64..128,
         {:ok, ip, port} <- FileConfig.listen(listen),
         true <- port in 1..65_535,
         {:ok, server} <-
           ServerConfig.new(
             Keyword.merge(service_options,
               ip: ip,
               port: port,
               public_origin: origin,
               exposure: :loopback,
               tls: nil
             )
           ),
         true <- matching_origin?(server) do
      {:ok,
       %__MODULE__{
         ip: ip,
         port: port,
         public_origin: origin,
         secret_key_base: secret
       }}
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  defp matching_origin?(config) do
    uri = URI.parse(config.public_origin)
    uri.port == config.port and uri.host in [to_string(:inet.ntoa(config.ip)), "localhost"]
  end
end
