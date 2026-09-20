defmodule Wotex.Tracker.Host.BrowserConfig do
  @moduledoc """
  Holds the standalone host's validated browser listener configuration.

  The host configuration loader checks the listener, public origin, exposure
  mode, TLS, and session-signing secret before constructing this value. Only
  the address, port, origin, and exposure appear in inspection; TLS material,
  prompt and map configuration, and the secret key remain omitted.
  """

  @derive {Inspect, only: [:ip, :port, :public_origin, :exposure]}
  @enforce_keys [:ip, :port, :public_origin, :exposure, :tls, :secret_key_base]
  defstruct @enforce_keys ++ [prompt: nil, map_pack: nil]

  @type t :: %__MODULE__{
          ip: :inet.ip_address(),
          port: :inet.port_number(),
          public_origin: String.t(),
          exposure: :loopback | :proxy | :tls,
          tls: map() | nil,
          secret_key_base: String.t(),
          prompt: Wotex.Tracker.Host.PromptConfig.t() | nil,
          map_pack: term()
        }
end
