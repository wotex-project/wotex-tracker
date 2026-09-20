defmodule Wotex.Tracker.Nerves.BrowserConfig do
  @moduledoc """
  Loads the Pi control panel's private loopback configuration.

  `load/3` accepts only `browser.json` under the writable private root. It
  checks the closed schema, file and directory policy, listener and matching
  origin, and session-signing secret before returning a listener configuration.
  A version-two document additionally binds the display to one configured scope
  and the matching private operator-token file. Inspection includes only the
  address, port, and origin, never the secret or device-session configuration.
  """

  import Bitwise
  @derive {Inspect, only: [:ip, :port, :public_origin]}
  @enforce_keys [:ip, :port, :public_origin, :secret_key_base, :device_session]
  defstruct @enforce_keys

  alias Wotex.Tracker.Service.Credentials
  alias Wotex.Tracker.Service.HTTP.Config, as: ServerConfig
  alias Wotex.Tracker.Service.HTTP.FileConfig
  alias Wotex.Tracker.Service.StorePath

  @spec load(term(), term(), keyword()) :: {:ok, %__MODULE__{}} | {:error, :invalid_configuration}
  def load(path, root, service_options) do
    with :ok <- StorePath.private_directory(root),
         true <- path == Path.join(root, "browser.json"),
         {:ok, document} <- FileConfig.read_document(path),
         {:ok, listen, origin, secret, device_session} <-
           browser_document(document, root, service_options),
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
         secret_key_base: secret,
         device_session: device_session
       }}
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  defp matching_origin?(config) do
    uri = URI.parse(config.public_origin)
    uri.port == config.port and uri.host in [to_string(:inet.ntoa(config.ip)), "localhost"]
  end

  defp browser_document(
         %{
           "schema" => "wtr.browser.v1",
           "listen" => listen,
           "exposure" => "loopback",
           "public_origin" => origin,
           "secret_key_base" => secret
         } = document,
         _root,
         _service_options
       )
       when map_size(document) == 5,
       do: {:ok, listen, origin, secret, nil}

  defp browser_document(
         %{
           "schema" => "wtr.browser.v2",
           "listen" => listen,
           "exposure" => "loopback",
           "public_origin" => origin,
           "secret_key_base" => secret,
           "device_session" => %{"scope" => scope} = device
         } = document,
         root,
         service_options
       )
       when map_size(document) == 6 and map_size(device) == 1 do
    token_file = Path.join(root, "operator.token")
    credentials = service_options[:credentials]

    with true <- is_binary(scope),
         :ok <- private_token_file(token_file, credentials, scope) do
      {:ok, listen, origin, secret, %{scope: scope, token_file: token_file}}
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  defp browser_document(_, _, _), do: {:error, :invalid_configuration}

  defp private_token_file(path, credentials, scope) do
    with {:ok, %{type: :regular, links: 1, size: 44, mode: mode}} <- File.lstat(path),
         true <- (mode &&& 0o777) == 0o600,
         {:ok, <<token::binary-size(43), "\n">>} <-
           File.open(path, [:read, :binary], &IO.binread(&1, 45)),
         {:ok, _access} <- Credentials.authenticate(credentials, token, scope, "read", 0) do
      :ok
    else
      _ -> {:error, :invalid_configuration}
    end
  end
end
