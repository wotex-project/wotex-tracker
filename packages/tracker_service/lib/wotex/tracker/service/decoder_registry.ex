defmodule Wotex.Tracker.Service.DecoderRegistry do
  @moduledoc false

  alias Wotex.Tracker.{Catalogue, Decoder, Error, Observation, Resolution}

  @type revision :: {String.t(), String.t()}
  @type t :: %{required(revision()) => (Observation.t() -> term())}

  def new(catalogue, configured) do
    with {:ok, catalogue} <- Catalogue.validate(catalogue),
         true <- is_list(configured),
         expected = MapSet.new(catalogue.profiles, & &1.decoder),
         true <- length(configured) == MapSet.size(expected),
         {:ok, registry} <- entries(configured, %{}),
         true <- MapSet.new(Map.keys(registry)) == expected do
      {:ok, registry}
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  def decode(observation, catalogue, registry) when is_map(registry) do
    with {:ok, observation} <- Observation.validate(observation),
         {:ok, resolution} <- Resolution.resolve(observation, catalogue) do
      decoded(observation, resolution, catalogue, registry)
    end
  end

  def decode(_, _, _), do: {:error, Error.new(:revision_mismatch, :decode)}

  defp entries([], registry), do: {:ok, registry}

  defp entries([{revision, callback} | rest], registry)
       when is_tuple(revision) and tuple_size(revision) == 2 and is_function(callback, 1) do
    if Map.has_key?(registry, revision),
      do: {:error, :invalid_configuration},
      else: entries(rest, Map.put(registry, revision, callback))
  end

  defp entries(_, _), do: {:error, :invalid_configuration}

  defp decoded(observation, %{status: :resolved} = resolution, catalogue, registry) do
    revision = resolution.selected.decoder

    Decoder.run(
      observation,
      resolution,
      catalogue,
      {revision, Map.get(registry, revision)}
    )
    |> case do
      {:ok, decoded} ->
        {:ok, %{observation: observation, resolution: resolution, decoded: decoded}}

      error ->
        error
    end
  end

  defp decoded(observation, resolution, _catalogue, _registry),
    do: {:ok, %{observation: observation, resolution: resolution, decoded: nil}}
end
