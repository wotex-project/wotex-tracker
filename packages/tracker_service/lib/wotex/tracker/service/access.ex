defmodule Wotex.Tracker.Service.Access do
  @moduledoc "An authenticated scope binding, rechecked before every operation or delivery."
  @derive {Inspect, only: [:principal, :scope]}
  @enforce_keys [:credential_id, :principal, :scope, :expires_at, :proof]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          credential_id: String.t(),
          principal: String.t(),
          scope: String.t(),
          expires_at: integer(),
          proof: binary()
        }
end
