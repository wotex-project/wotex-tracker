defmodule Wotex.Tracker.Service.Access do
  @moduledoc """
  Holds the service's authenticated credential and scope binding.

  `Wotex.Tracker.Service.authorize/5` returns this value after checking the
  requested permission. Service operations and delivery paths recheck current
  authority rather than treating a retained struct as a permanent grant. Its
  inspection omits the credential ID and proof; callers must not serialize the
  proof into a browser response or operational event.
  """

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
