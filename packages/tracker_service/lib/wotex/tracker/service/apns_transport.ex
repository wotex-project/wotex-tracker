defmodule Wotex.Tracker.Service.APNsTransport do
  @moduledoc false

  @type request :: %{
          host: String.t(),
          path: String.t(),
          headers: [{String.t(), String.t()}],
          body: binary(),
          timeout_ms: pos_integer()
        }

  @callback request(term(), request()) ::
              {:ok, 100..599, [{String.t(), String.t()}], binary()}
              | {:error, :timeout | :unavailable | :response_rejected}
end
