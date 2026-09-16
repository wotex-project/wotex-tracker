defmodule Wotex.Tracker.UI.Client do
  @moduledoc "Explicit authorized service boundary for local and remote presentation hosts."

  @type t :: {module(), term()}
  @type result :: {:ok, map()} | {:error, map()}
  @callback request(term(), String.t(), String.t(), atom(), map(), integer()) :: result()
end
