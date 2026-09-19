defmodule Wotex.Tracker.Mobile.Config do
  @moduledoc """
  Closed local-runtime configuration for one mobile application instance.

  The local listener is always numeric IPv4 loopback HTTP. The remote service
  remains an exact HTTPS origin handled by the shared bounded client.
  """

  alias Wotex.Tracker.Mobile.{DNS, RemoteTransport, WebSession}
  alias Wotex.Tracker.UI.{Remote, RemoteMintTransport}

  @keys ~w(directory remote_origin port secret_key_base capability remote_transport timeout_ms)a
  @derive {Inspect, only: [:origin, :directory, :remote_origin, :port]}
  @enforce_keys [
    :directory,
    :remote_origin,
    :port,
    :origin,
    :secret_key_base,
    :capability_digest,
    :remote,
    :web_session
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          directory: String.t(),
          remote_origin: String.t(),
          port: :inet.port_number(),
          origin: String.t(),
          secret_key_base: String.t(),
          capability_digest: binary(),
          remote: Remote.t(),
          web_session: WebSession.t()
        }

  @doc "Generates a canonical ephemeral native app-session capability."
  @spec generate_capability() :: String.t()
  def generate_capability,
    do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  @doc "Builds an exact loopback/mobile-to-service composition."
  @spec new(keyword()) :: {:ok, t()} | {:error, :invalid_configuration}
  def new(options) when is_list(options) do
    with true <- Keyword.keyword?(options),
         true <- length(options) == map_size(Map.new(options)),
         [] <- Keyword.keys(options) -- @keys,
         directory when is_binary(directory) <- Keyword.get(options, :directory),
         true <- Path.type(directory) == :absolute and Path.expand(directory) == directory,
         remote_origin when is_binary(remote_origin) <- Keyword.get(options, :remote_origin),
         port when port in 1..65_535 <- Keyword.get(options, :port),
         secret when is_binary(secret) and byte_size(secret) in 64..256 <-
           Keyword.get(options, :secret_key_base),
         capability when is_binary(capability) <- Keyword.get(options, :capability),
         origin = "http://127.0.0.1:#{port}",
         {:ok, web_session} <- WebSession.new(origin, capability),
         transport <- Keyword.get(options, :remote_transport, default_transport()),
         timeout <- Keyword.get(options, :timeout_ms, 5_000),
         {:ok, remote} <-
           Remote.new(origin: remote_origin, transport: transport, timeout_ms: timeout) do
      {:ok,
       %__MODULE__{
         directory: directory,
         remote_origin: remote_origin,
         port: port,
         origin: origin,
         secret_key_base: secret,
         capability_digest: :crypto.hash(:sha256, capability),
         remote: remote,
         web_session: web_session
       }}
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  def new(_), do: {:error, :invalid_configuration}

  defp default_transport do
    {RemoteTransport,
     %{
       resolver: {DNS, nil},
       transport: {RemoteMintTransport, {Mint.HTTP, &:public_key.cacerts_get/0}}
     }}
  end
end
