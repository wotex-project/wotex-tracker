defmodule Wotex.Tracker.Service.OperationalExportAdapter do
  @moduledoc """
  Host-supplied delivery boundary for sanitized operational batches.

  A destination adapter owns its endpoint authentication and transport. Calls
  run outside telemetry handlers and the collector process. Because an exporter
  retries a failed or timed-out batch with the same epoch and checkpoint, an
  adapter must make delivery idempotent for that identity.
  """

  @type outcome :: :ok | {:error, :rejected | :unavailable}

  @doc "Delivers one closed `wtr.operational-export.v1` batch."
  @callback deliver(context :: term(), batch :: map()) :: outcome()
end
