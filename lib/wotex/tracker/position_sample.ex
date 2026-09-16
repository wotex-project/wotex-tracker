defmodule Wotex.Tracker.PositionSample do
  @moduledoc """
  A validated position plus optional protocol-sequence evidence.

  Sequence evidence is a closed transport claim in the same immutable bundle.
  Its scope distinguishes devices or streams, while its session identifies the
  reconnect interval in which the modular counter is meaningful.
  """

  alias Wotex.Tracker.{Admission, Error, EvidenceBundle, Limits, Position}

  @sequence_fields ~w(schema scope_id session_id value modulus receiver_observation_id)
  @serialized_fields ~w(schema identity position_evidence_id position_bundle_identity received_at sequence_evidence_id sequence bundle)
  @type t :: %__MODULE__{}
  @enforce_keys [:position, :bundle, :sequence_evidence_id, :sequence, :identity]
  defstruct @enforce_keys

  @doc "Admits a position and optional sequence evidence without interpreting order."
  @spec new(term(), term(), term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(position, bundle, sequence_evidence_id \\ nil, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         {:ok, bundle} <- EvidenceBundle.validate(bundle, options),
         {:ok, position} <- Position.validate(position, bundle, options),
         {:ok, sequence} <- sequence(bundle, position, sequence_evidence_id, limits),
         {:ok, identity} <-
           Admission.digest(identity_map(position, sequence), Limits.json(limits)) do
      {:ok,
       %__MODULE__{
         position: position,
         bundle: bundle,
         sequence_evidence_id: sequence_evidence_id,
         sequence: sequence,
         identity: identity
       }}
    end
  end

  @doc "Revalidates the complete bundle, position, sequence claim and sample identity."
  @spec validate(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(value, options \\ [])

  def validate(%__MODULE__{} = sample, options) do
    with {:ok, admitted} <-
           new(sample.position, sample.bundle, sample.sequence_evidence_id, options) do
      if admitted === sample, do: {:ok, admitted}, else: Admission.fail(:conflict)
    end
  end

  def validate(_, _), do: Admission.fail(:invalid_input)

  @doc "Exports the ordering inputs and complete immutable evidence bundle to native JSON."
  @spec to_map(term(), term()) :: {:ok, map()} | {:error, Error.t()}
  def to_map(sample, options \\ []) do
    with {:ok, sample} <- validate(sample, options),
         {:ok, bundle} <- EvidenceBundle.to_map(sample.bundle, options) do
      {:ok,
       %{
         "schema" => "wtr.position-sample.v1",
         "identity" => sample.identity,
         "position_evidence_id" => sample.position.evidence_id,
         "position_bundle_identity" => sample.position.bundle_identity,
         "received_at" => sample.position.claim["received_at"],
         "sequence_evidence_id" => sample.sequence_evidence_id,
         "sequence" => sample.sequence,
         "bundle" => bundle
       }}
    end
  end

  @doc "Restores and revalidates a position sample from closed native JSON."
  @spec from_map(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(document, options \\ []) do
    with true <- exact_fields?(document, @serialized_fields),
         true <- document["schema"] == "wtr.position-sample.v1",
         {:ok, bundle} <- EvidenceBundle.from_map(document["bundle"], options),
         {:ok, position} <- Position.new(document["position_evidence_id"], bundle, options),
         {:ok, sample} <-
           new(position, bundle, document["sequence_evidence_id"], options),
         {:ok, admitted} <- to_map(sample, options),
         true <- admitted === document do
      {:ok, sample}
    else
      false -> Admission.fail(:conflict)
      error -> error
    end
  end

  defp sequence(_bundle, _position, nil, _limits), do: {:ok, nil}

  defp sequence(bundle, position, id, limits) do
    with :ok <- Admission.id(id, limits),
         {:ok, evidence} <- Map.fetch(bundle.evidence, id),
         true <- evidence.kind == :transport,
         true <- id in bundle.evidence[position.evidence_id].evidence_ids,
         :ok <- sequence_claim(evidence.claim, limits),
         true <-
           evidence.claim["receiver_observation_id"] == position.claim["receiver_observation_id"],
         true <- evidence.claim["receiver_observation_id"] in evidence.source_observation_ids do
      {:ok, evidence.claim}
    else
      :error -> Admission.fail(:dangling_reference)
      false -> Admission.fail(:conflict)
      error -> error
    end
  end

  defp sequence_claim(claim, limits) do
    valid_shape =
      is_map(claim) and map_size(claim) == length(@sequence_fields) and
        Enum.all?(@sequence_fields, &Map.has_key?(claim, &1))

    with true <- valid_shape and claim["schema"] == "wtr.sequence.v1",
         :ok <- Admission.id(claim["scope_id"], limits),
         :ok <- Admission.id(claim["session_id"], limits),
         :ok <- Admission.id(claim["receiver_observation_id"], limits),
         true <- is_integer(claim["modulus"]) and claim["modulus"] in 3..4_294_967_296,
         true <- is_integer(claim["value"]) and claim["value"] in 0..(claim["modulus"] - 1) do
      :ok
    else
      false -> Admission.fail(:invalid_input)
      error -> error
    end
  end

  defp identity_map(position, sequence),
    do: %{
      "schema" => "wtr.position-sample.v1",
      "algorithm" => "evidence-bound-position-sample-v1",
      "position_evidence_id" => position.evidence_id,
      "position_bundle_identity" => position.bundle_identity,
      "sequence" => sequence
    }

  defp exact_fields?(value, fields),
    do:
      is_map(value) and not is_struct(value) and
        Enum.sort(Map.keys(value)) == Enum.sort(fields)
end
