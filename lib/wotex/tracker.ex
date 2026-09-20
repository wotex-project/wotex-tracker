defmodule Wotex.Tracker do
  @moduledoc """
  Headless facade for explicit, pure observation-to-Thing operations.

  Loading Tracker starts no Tracker application tree. Importing never scans,
  enrolls, publishes or executes a Thing Form. Unknown and ambiguous observations
  remain successful domain results, with no decoder execution.

      iex> {:ok, catalogue} = Wotex.Tracker.catalogue([])
      ...> catalogue.profiles
      []
  """

  alias Wotex.Tracker.{Catalogue, Decoder, Error, Materialisation, Observation, Resolution}

  @doc "Admits explicit capture facts."
  @spec observation(term(), term()) :: {:ok, Observation.t()} | {:error, Error.t()}
  defdelegate observation(input, options \\ []), to: Observation, as: :new

  @doc "Builds an immutable profile catalogue."
  @spec catalogue(term(), term()) :: {:ok, Catalogue.t()} | {:error, Error.t()}
  defdelegate catalogue(profiles, options \\ []), to: Catalogue, as: :new

  @doc "Resolves an admitted observation without running a decoder."
  @spec resolve(term(), term(), term()) :: {:ok, Resolution.t()} | {:error, Error.t()}
  defdelegate resolve(observation, catalogue, options \\ []), to: Resolution

  @doc "Re-resolves passive candidates using one admitted profile-owned probe result."
  @spec resolve_with_probe(term(), term(), term(), term()) ::
          {:ok, Resolution.t()} | {:error, Error.t()}
  defdelegate resolve_with_probe(observation, catalogue, result, options \\ []), to: Resolution

  @doc "Imports an admitted observation, retaining unresolved evidence and using only an explicit decoder."
  @spec import_observation(term(), term(), term(), term()) :: {:ok, map()} | {:error, Error.t()}
  def import_observation(observation, catalogue, decoder, options \\ []) do
    with {:ok, observation} <- Observation.validate(observation, options),
         {:ok, resolution} <- resolve(observation, catalogue, options) do
      import_result(resolution, observation, catalogue, decoder, options)
    end
  end

  defp import_result(%{status: :resolved} = resolution, observation, catalogue, decoder, options) do
    with {:ok, decoded} <- Decoder.run(observation, resolution, catalogue, decoder, options),
         do: {:ok, %{observation: observation, resolution: resolution, decoded: decoded}}
  end

  defp import_result(resolution, observation, _catalogue, _decoder, _options),
    do: {:ok, %{observation: observation, resolution: resolution, decoded: nil}}

  @doc "Builds a validated Thing Description from explicit model, identity, evidence and deployment inputs."
  @spec materialize(term(), term()) :: {:ok, Materialisation.t()} | {:error, Error.t()}
  defdelegate materialize(input, options \\ []), to: Materialisation, as: :new
end
