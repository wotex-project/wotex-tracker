defmodule Wotex.Tracker.Service.ActiveProbeAdapter do
  @moduledoc """
  Explicit transport boundary for one authorized read-only active probe.

  The probe owner supplies only a closed transport request and a finite timeout.
  Service credentials, access proofs and retained evidence never cross this
  callback. The owner runs every callback in a monitored process and may
  terminate it when the caller disappears, cancels or exceeds its deadline.
  """

  @type outcome :: {:ok, binary()} | {:error, :rejected | :unavailable}

  @doc "Reads one bounded value without retrying or mutating the selected peer."
  @callback read(context :: term(), request :: map(), timeout_ms :: pos_integer()) :: outcome()
end
