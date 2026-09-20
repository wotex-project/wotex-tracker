defmodule Wotex.Tracker.Service.AgentAdapter do
  @moduledoc """
  Explicit provider boundary for one bounded agent investigation.

  The connector supplies a closed provider request and a synchronous emitter.
  Returning an emitter error stops useful work; the connector may terminate an
  adapter process that ignores cancellation or its absolute deadline.
  """

  alias Wotex.Tracker.Service.AgentConnectorConfig

  @type emitter :: (map() -> :ok | {:error, :cancelled | :response_too_large})
  @type outcome ::
          {:ok, map()}
          | {:error, :rejected | :unavailable}

  @doc "Runs one request without receiving service credentials or private Thing state."
  @callback investigate(
              context :: term(),
              AgentConnectorConfig.t(),
              request :: map(),
              emitter()
            ) :: outcome()
end
