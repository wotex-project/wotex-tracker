defmodule Wotex.Tracker.Service.DecoderRegistry do
  @moduledoc false

  alias Wotex.Tracker.{Catalogue, Decoder, Error, Observation, Resolution}
  alias Wotex.Tracker.Protocols.Teltonika.TAT140Import

  @type revision :: {String.t(), String.t()}
  @type snapshot_callback :: (Observation.t() -> term())
  @type record_callback :: (Observation.t(), Catalogue.t() -> term())
  @type entry :: {:snapshot, snapshot_callback()} | {:records, record_callback()}
  @type t :: %{required(revision()) => entry()}

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
    put_entry(rest, registry, revision, {:snapshot, callback})
  end

  defp entries([{revision, {:records, callback}} | rest], registry)
       when is_tuple(revision) and tuple_size(revision) == 2 and is_function(callback, 2),
       do: put_entry(rest, registry, revision, {:records, callback})

  defp entries(_, _), do: {:error, :invalid_configuration}

  defp put_entry(rest, registry, revision, entry) do
    if Map.has_key?(registry, revision),
      do: {:error, :invalid_configuration},
      else: entries(rest, Map.put(registry, revision, entry))
  end

  defp decoded(observation, %{status: :resolved} = resolution, catalogue, registry) do
    revision = resolution.selected.decoder

    decode_entry(registry[revision], observation, resolution, catalogue, revision)
    |> case do
      {:ok, decoded} ->
        {:ok, %{observation: observation, resolution: resolution, decoded: decoded}}

      error ->
        error
    end
  end

  defp decoded(observation, resolution, _catalogue, _registry),
    do: {:ok, %{observation: observation, resolution: resolution, decoded: nil}}

  defp decode_entry({:snapshot, callback}, observation, resolution, catalogue, revision),
    do: Decoder.run(observation, resolution, catalogue, {revision, callback})

  defp decode_entry({:records, callback}, observation, resolution, catalogue, _revision) do
    with {:ok, %TAT140Import{} = imported} <- callback.(observation, catalogue),
         true <- imported.resolution === resolution do
      TAT140Import.validate(imported, observation, catalogue, [])
    else
      _ -> {:error, Error.new(:invalid_decoder_result, :decode)}
    end
  end

  defp decode_entry(_, _, _, _, _), do: {:error, Error.new(:revision_mismatch, :decode)}
end
