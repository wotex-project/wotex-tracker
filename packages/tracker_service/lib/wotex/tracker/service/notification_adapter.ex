defmodule Wotex.Tracker.Service.NotificationAdapter do
  @moduledoc """
  Explicit provider boundary for one minimal mobile notification.

  Provider acceptance is not OS delivery or evidence that a person read the
  notification. Adapters receive a private endpoint target and the closed opaque
  reference payload; they must not add location, credentials or raw evidence.
  """

  alias Wotex.Tracker.Service.NotificationTarget

  @type result ::
          {:accepted, String.t()}
          | {:invalid_token, String.t()}
          | {:rejected, String.t()}
          | {:retry, :unavailable | :timeout | :rate_limited | :server_error}

  @callback deliver(term(), NotificationTarget.t(), map()) :: result()
end
