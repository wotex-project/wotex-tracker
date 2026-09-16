defmodule Wotex.Tracker.Host.BrowserConfig do
  @moduledoc "Validated browser configuration with secrets and private paths redacted from inspection."
  @derive {Inspect, only: [:ip, :port, :public_origin, :exposure]}
  @enforce_keys [:ip, :port, :public_origin, :exposure, :tls, :secret_key_base]
  defstruct @enforce_keys ++ [prompt: nil]

  @type t :: %__MODULE__{
          ip: :inet.ip_address(),
          port: :inet.port_number(),
          public_origin: String.t(),
          exposure: :loopback | :proxy | :tls,
          tls: map() | nil,
          secret_key_base: String.t(),
          prompt: Wotex.Tracker.Host.PromptConfig.t() | nil
        }
end
