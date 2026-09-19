defmodule Wotex.Tracker.Service.NotificationTarget do
  @moduledoc """
  Private delivery target passed only to a configured notification adapter.

  The token is deliberately excluded from inspection. Adapters must keep the
  target in process memory, use it only for the current provider request and
  never log or persist it.
  """

  @derive {Inspect, only: [:id, :provider, :app_id, :environment, :revision]}
  @enforce_keys [
    :scope,
    :internal_id,
    :id,
    :provider,
    :app_id,
    :environment,
    :revision,
    :token,
    :access
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          scope: String.t(),
          internal_id: String.t(),
          id: String.t(),
          provider: String.t(),
          app_id: String.t(),
          environment: String.t(),
          revision: String.t(),
          token: String.t(),
          access: Wotex.Tracker.Service.Access.t()
        }
end
