defmodule Wotex.Tracker.Service.PassiveScanAdapter do
  @moduledoc """
  Pull boundary for a host-owned passive BLE scanner.

  `init/1` and `next/1` are called only by `PassiveScanner`. One `next/1` call is
  isolated behind a finite deadline, so a native adapter cannot block the
  service supervisor. Returning `:idle` applies backpressure: another capture is
  not requested until the configured interval elapses.
  """

  alias Wotex.Tracker.Service.PassiveAdvertisement

  @type state :: term()
  @type next_result ::
          {:ok, PassiveAdvertisement.t(), state()}
          | {:idle, state()}
          | {:stop, state()}
          | {:error, term(), state()}

  @callback init(term()) :: {:ok, state()} | {:error, term()}
  @callback next(state()) :: next_result()
  @callback terminate(term(), state()) :: term()

  @optional_callbacks terminate: 2
end
