defmodule Wotex.Tracker.UI.RemoteTransport do
  @moduledoc """
  Defines the bounded HTTP exchange owned by a remote presentation host.

  The callback receives an admitted origin and one closed request. It must not
  retain credentials after returning and must never follow redirects.
  """

  @type origin :: %{scheme: :http | :https, host: String.t(), port: pos_integer()}
  @type request :: %{
          method: String.t(),
          path: String.t(),
          headers: [{String.t(), String.t()}],
          body: binary(),
          timeout_ms: pos_integer()
        }
  @type response :: {:ok, 100..599, [{String.t(), String.t()}], binary()}

  @callback request(term(), origin(), request()) :: response() | {:error, atom()}
end
