defmodule Wotex.Tracker.MeasurementSample do
  @moduledoc """
  A measurement evidence record bound to its complete bundle and receiver time.

  When evidence names multiple source observations, the latest receiver capture
  is selected by a deterministic time, ID and content-identity order.
  """
  alias Wotex.Tracker.{Admission, Error, EvidenceBundle, Limits, Measurement, Observation}

  @type t :: %__MODULE__{}
  @enforce_keys [
    :evidence,
    :bundle,
    :measurement,
    :observed_at,
    :observation_id,
    :observation_identity,
    :identity
  ]
  defstruct @enforce_keys

  @doc "Builds a receiver-timed sample from one measurement evidence ID."
  @spec new(term(), term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(evidence_id, bundle, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         :ok <- Admission.id(evidence_id, limits),
         {:ok, bundle} <- EvidenceBundle.validate(bundle, options),
         {:ok, evidence} <- fetch_measurement(bundle, evidence_id),
         {:ok, measurement} <- Measurement.from_map(evidence.claim, options),
         {:ok, observation, observation_identity} <-
           latest_observation(evidence.source_observation_ids, bundle, options),
         {:ok, identity} <-
           Admission.digest(
             sample_map(
               evidence.id,
               bundle.identity,
               observation.id,
               observation_identity,
               observation.observed_at
             ),
             Limits.json(limits)
           ) do
      {:ok,
       %__MODULE__{
         evidence: evidence,
         bundle: bundle,
         measurement: measurement,
         observed_at: observation.observed_at,
         observation_id: observation.id,
         observation_identity: observation_identity,
         identity: identity
       }}
    end
  end

  @doc "Rebuilds the sample and rejects modified evidence, timing or identity."
  @spec validate(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(value, options \\ [])

  def validate(%__MODULE__{} = value, options) do
    with {:ok, admitted} <- new(value.evidence.id, value.bundle, options) do
      if admitted === value, do: {:ok, admitted}, else: Admission.fail(:conflict)
    end
  end

  def validate(_, _), do: Admission.fail(:invalid_input)

  @doc "Projects a validated sample and its complete evidence bundle to native JSON."
  @spec to_map(term(), term()) :: {:ok, map()} | {:error, Error.t()}
  def to_map(value, options \\ []) do
    with {:ok, sample} <- validate(value, options),
         {:ok, bundle} <- EvidenceBundle.to_map(sample.bundle, options) do
      {:ok,
       %{
         "schema" => "wtr.measurement-sample.v1",
         "evidence_id" => sample.evidence.id,
         "bundle" => bundle,
         "identity" => sample.identity
       }}
    end
  end

  @doc "Restores and revalidates a sample from its complete native-JSON bundle."
  @spec from_map(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(document, options \\ []) do
    with true <-
           is_map(document) and not is_struct(document) and
             Enum.sort(Map.keys(document)) == ~w(bundle evidence_id identity schema),
         true <- document["schema"] == "wtr.measurement-sample.v1",
         {:ok, bundle} <- EvidenceBundle.from_map(document["bundle"], options),
         {:ok, sample} <- new(document["evidence_id"], bundle, options),
         true <- sample.identity == document["identity"] do
      {:ok, sample}
    else
      false -> Admission.fail(:conflict)
      error -> error
    end
  end

  defp fetch_measurement(bundle, evidence_id) do
    case Map.fetch(bundle.evidence, evidence_id) do
      {:ok, %{kind: :measurement} = evidence} -> {:ok, evidence}
      {:ok, _} -> Admission.fail(:conflict)
      :error -> Admission.fail(:dangling_reference)
    end
  end

  defp latest_observation(ids, bundle, options) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, observations} ->
      with {:ok, observation} <- Map.fetch(bundle.observations, id),
           {:ok, identity} <- Observation.identity(observation, options) do
        {:cont, {:ok, [{observation, identity} | observations]}}
      else
        :error -> {:halt, Admission.fail(:dangling_reference)}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, observations} ->
        {observation, identity} =
          Enum.max_by(observations, fn {observation, identity} ->
            [observation.observed_at, observation.id, identity]
          end)

        {:ok, observation, identity}

      error ->
        error
    end
  end

  defp sample_map(
         evidence_id,
         bundle_identity,
         observation_id,
         observation_identity,
         observed_at
       ),
       do: %{
         "schema" => "wtr.measurement-sample.v1",
         "algorithm" => "latest-receiver-source-v1",
         "evidence_id" => evidence_id,
         "bundle_identity" => bundle_identity,
         "observation_id" => observation_id,
         "observation_identity" => observation_identity,
         "observed_at" => observed_at
       }
end
