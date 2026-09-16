defmodule Wotex.Tracker.UI.Client do
  @moduledoc """
  Defines the service request boundary used by shared browser screens.

  A host supplies `{module, context}` to `Wotex.Tracker.UI.Sessions`. The
  callback receives a server-held credential, scope, closed action, arguments,
  and current Unix milliseconds. It returns a public result or a coded error.
  Presentation modules never receive the bearer token, and an implementation
  must preserve the service's authorization and commit outcome semantics.
  """

  @type t :: {module(), term()}
  @type result :: {:ok, map() | binary()} | {:error, map()}
  @callback request(term(), String.t(), String.t(), atom(), map(), integer()) :: result()
end
