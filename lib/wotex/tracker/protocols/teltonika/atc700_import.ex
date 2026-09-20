defmodule Wotex.Tracker.Protocols.Teltonika.ATC700Import do
  @moduledoc """
  Facade for the shared record-aware ATC700 import.

  Returned values use `Wotex.Tracker.Protocols.Teltonika.RecordImport`, whose
  closed contract field binds validation to the ATC700 profile.
  """

  alias Wotex.Tracker.Error
  alias Wotex.Tracker.Protocols.Teltonika.RecordImport

  @contract :teltonika_atc700_codec8e

  @doc "Builds ordered record evidence for the exact configured ATC700 profile."
  @spec run(term(), term(), term()) :: {:ok, RecordImport.t()} | {:error, Error.t()}
  def run(observation, catalogue, options \\ []),
    do: RecordImport.run(observation, catalogue, @contract, options)

  @doc "Re-runs the pure ATC700 record import and rejects forged or stale content."
  @spec validate(term(), term(), term(), term()) ::
          {:ok, RecordImport.t()} | {:error, Error.t()}
  def validate(value, observation, catalogue, options \\ []) do
    if RecordImport.contract?(value, @contract),
      do: RecordImport.validate(value, observation, catalogue, options),
      else: {:error, Error.new(:invalid_decoder_result, :decode)}
  end
end
