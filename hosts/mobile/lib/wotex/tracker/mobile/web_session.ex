defmodule Wotex.Tracker.Mobile.WebSession do
  @moduledoc """
  Closed native-WebView target for one ephemeral local app session.

  Only an exact numeric loopback HTTP origin and canonical 32-byte URL-safe
  capability are admitted. Page content never supplies this value.
  """

  @derive {Inspect, only: [:origin]}
  @enforce_keys [:origin, :capability]
  defstruct @enforce_keys

  @type t :: %__MODULE__{origin: String.t(), capability: String.t()}

  @doc "Builds the one permitted WebView navigation target."
  @spec new(String.t(), String.t()) :: {:ok, t()} | {:error, :invalid_configuration}
  def new(origin, capability) when is_binary(origin) and is_binary(capability) do
    with %URI{scheme: "http", host: "127.0.0.1", path: path} = uri <- URI.parse(origin),
         true <- path in [nil, ""],
         true <- is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment),
         port when port in 1..65_535 <- uri.port,
         true <- URI.to_string(%URI{scheme: "http", host: "127.0.0.1", port: port}) == origin,
         {:ok, bytes} <- Base.url_decode64(capability, padding: false),
         true <- byte_size(bytes) == 32,
         true <- Base.url_encode64(bytes, padding: false) == capability do
      {:ok, %__MODULE__{origin: origin, capability: capability}}
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  def new(_, _), do: {:error, :invalid_configuration}

  @doc "Returns the bootstrap URL and exact navigation allow-prefix."
  @spec target(t()) :: %{url: String.t(), allow: [String.t()]}
  def target(%__MODULE__{} = session) do
    %{
      url: session.origin <> "/_mobile/bootstrap/" <> session.capability,
      allow: [session.origin <> "/"]
    }
  end
end
