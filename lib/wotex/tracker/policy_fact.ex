defmodule Wotex.Tracker.PolicyFact do
  @moduledoc """
  A three-valued policy fact bound to retained evidence and receiver time.

  Facts expose the policy revision that derived true, false or unknown. They do
  not infer truth from radio reception, missing evidence or a capability name.
  """

  alias Wotex.Tracker.{Admission, Error, EvidenceBundle, Limits}

  @claim_fields ~w(schema predicate status policy_revision reason)
  @serialized_fields ~w(schema identity evidence_id bundle_identity predicate status policy_revision reason observed_at observation_id bundle)
  @type t :: %__MODULE__{}
  @enforce_keys [
    :evidence,
    :bundle,
    :predicate,
    :status,
    :policy_revision,
    :reason,
    :observed_at,
    :observation_id,
    :identity
  ]
  defstruct @enforce_keys

  @doc "Builds an exact/strong three-valued fact from a closed evidence bundle."
  @spec new(term(), term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(evidence_id, bundle, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         :ok <- Admission.id(evidence_id, limits),
         {:ok, bundle} <- EvidenceBundle.validate(bundle, options),
         {:ok, evidence} <- fetch(bundle, evidence_id),
         :ok <- claim(evidence.claim, limits),
         {:ok, observation} <- latest_observation(evidence.source_observation_ids, bundle),
         {:ok, identity} <-
           Admission.digest(
             fact_map(evidence, bundle, observation),
             Limits.json(limits)
           ) do
      {:ok,
       %__MODULE__{
         evidence: evidence,
         bundle: bundle,
         predicate: evidence.claim["predicate"],
         status: evidence.claim["status"],
         policy_revision: evidence.claim["policy_revision"],
         reason: evidence.claim["reason"],
         observed_at: observation.observed_at,
         observation_id: observation.id,
         identity: identity
       }}
    end
  end

  @doc "Rebuilds the fact and rejects changed evidence, bundle, time or identity."
  @spec validate(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(value, options \\ [])

  def validate(%__MODULE__{} = value, options) do
    with {:ok, admitted} <- new(value.evidence.id, value.bundle, options) do
      if admitted === value, do: {:ok, admitted}, else: Admission.fail(:conflict)
    end
  end

  def validate(_, _), do: Admission.fail(:invalid_input)

  @doc "Exports the fact inputs and complete immutable evidence bundle to native JSON."
  @spec to_map(term(), term()) :: {:ok, map()} | {:error, Error.t()}
  def to_map(value, options \\ []) do
    with {:ok, fact} <- validate(value, options),
         {:ok, bundle} <- EvidenceBundle.to_map(fact.bundle, options) do
      {:ok,
       %{
         "schema" => "wtr.policy-fact-sample.v1",
         "identity" => fact.identity,
         "evidence_id" => fact.evidence.id,
         "bundle_identity" => fact.bundle.identity,
         "predicate" => fact.predicate,
         "status" => fact.status,
         "policy_revision" => fact.policy_revision,
         "reason" => fact.reason,
         "observed_at" => fact.observed_at,
         "observation_id" => fact.observation_id,
         "bundle" => bundle
       }}
    end
  end

  @doc "Restores and revalidates an evidence-backed fact from closed native JSON."
  @spec from_map(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(document, options \\ []) do
    with true <- exact_fields?(document, @serialized_fields),
         true <- document["schema"] == "wtr.policy-fact-sample.v1",
         {:ok, bundle} <- EvidenceBundle.from_map(document["bundle"], options),
         {:ok, fact} <- new(document["evidence_id"], bundle, options),
         {:ok, admitted} <- to_map(fact, options),
         true <- admitted === document do
      {:ok, fact}
    else
      false -> Admission.fail(:conflict)
      error -> error
    end
  end

  defp fetch(bundle, evidence_id) do
    case Map.fetch(bundle.evidence, evidence_id) do
      {:ok, %{confidence: confidence} = evidence} when confidence in [:exact, :strong] ->
        {:ok, evidence}

      {:ok, _} ->
        Admission.fail(:conflict)

      :error ->
        Admission.fail(:dangling_reference)
    end
  end

  defp claim(claim, limits) do
    with true <-
           is_map(claim) and map_size(claim) == length(@claim_fields) and
             Enum.all?(@claim_fields, &Map.has_key?(claim, &1)),
         true <- claim["schema"] == "wtr.policy-fact.v1",
         true <- claim["status"] in ~w(true false unknown),
         :ok <-
           Admission.each(
             [claim["predicate"], claim["policy_revision"], claim["reason"]],
             &Admission.id(&1, limits)
           ) do
      :ok
    else
      false -> Admission.fail(:invalid_input)
      error -> error
    end
  end

  defp latest_observation(ids, bundle) do
    observations = Enum.map(ids, &Map.fetch!(bundle.observations, &1))
    {:ok, Enum.max_by(observations, &[&1.observed_at, &1.id])}
  end

  defp fact_map(evidence, bundle, observation),
    do: %{
      "schema" => "wtr.policy-fact-sample.v1",
      "algorithm" => "latest-receiver-source-v1",
      "evidence_id" => evidence.id,
      "bundle_identity" => bundle.identity,
      "predicate" => evidence.claim["predicate"],
      "status" => evidence.claim["status"],
      "policy_revision" => evidence.claim["policy_revision"],
      "reason" => evidence.claim["reason"],
      "observation_id" => observation.id,
      "observed_at" => observation.observed_at
    }

  defp exact_fields?(value, fields),
    do:
      is_map(value) and not is_struct(value) and
        Enum.sort(Map.keys(value)) == Enum.sort(fields)
end
