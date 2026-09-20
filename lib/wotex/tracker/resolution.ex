defmodule Wotex.Tracker.Resolution do
  @moduledoc """
  Pure deterministic resolution bound to one admitted observation and catalogue.
  Exact/strong ties remain ambiguous. Candidate-only matches remain unknown.
  One admitted active-probe result may strengthen or reject only its declared
  passive candidate. Names, catalogue order and decoder behavior never select a
  winner.
  """

  alias Wotex.Tracker.{
    Admission,
    Catalogue,
    DeviceProfile,
    Error,
    Limits,
    Observation,
    Predicate,
    ProbeContract,
    ProbeEvidence
  }

  @rank %{exact: 3, strong: 2, candidate: 1, unknown: 0}
  @type t :: %__MODULE__{
          status: :resolved | :unknown | :ambiguous,
          reason: atom(),
          selected: DeviceProfile.t() | nil,
          confidence: :exact | :strong | nil,
          candidates: [map()],
          catalogue_identity: String.t(),
          observation_identity: String.t(),
          probe_evidence: ProbeEvidence.t() | nil
        }
  @enforce_keys ~w(status reason selected confidence candidates catalogue_identity observation_identity probe_evidence)a
  defstruct @enforce_keys

  @doc "Resolves all admitted profiles without invoking any decoder."
  @spec resolve(term(), term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def resolve(observation, catalogue, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         {:ok, observation} <- Observation.validate(observation, options),
         {:ok, catalogue} <- Catalogue.validate(catalogue, options),
         {:ok, observation_identity} <- Observation.identity(observation, options),
         candidates = candidates(catalogue, observation),
         :ok <- Admission.bounded_list(candidates, limits.max_candidates) do
      {:ok, build(candidates, catalogue, observation_identity, nil)}
    end
  end

  @doc "Re-resolves passive candidates using one admitted profile-owned probe result."
  @spec resolve_with_probe(term(), term(), term(), term()) ::
          {:ok, t()} | {:error, Error.t()}
  def resolve_with_probe(observation, catalogue, result, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         {:ok, observation} <- Observation.validate(observation, options),
         {:ok, catalogue} <- Catalogue.validate(catalogue, options),
         {:ok, observation_identity} <- Observation.identity(observation, options),
         candidates = candidates(catalogue, observation),
         :ok <- Admission.bounded_list(candidates, limits.max_candidates),
         {:ok, evidence} <- ProbeEvidence.new(result, observation, catalogue, options),
         :ok <- passive_candidate(candidates, evidence.profile),
         {:ok, matched?} <- ProbeContract.match?(evidence.contract, evidence.value, options) do
      candidates = apply_probe(candidates, evidence, matched?)
      {:ok, build(candidates, catalogue, observation_identity, evidence)}
    end
  end

  @doc "Recomputes resolution to reject forged results and changed snapshot inputs."
  @spec validate(term(), term(), term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(value, observation, catalogue, options \\ [])

  def validate(%__MODULE__{probe_evidence: nil} = value, observation, catalogue, options) do
    with {:ok, resolution} <- resolve(observation, catalogue, options),
         true <- resolution === value do
      {:ok, resolution}
    else
      false -> Admission.fail(:conflict)
      error -> error
    end
  end

  def validate(
        %__MODULE__{probe_evidence: %ProbeEvidence{document: result}} = value,
        observation,
        catalogue,
        options
      ) do
    with {:ok, resolution} <- resolve_with_probe(observation, catalogue, result, options),
         true <- resolution === value do
      {:ok, resolution}
    else
      false -> Admission.fail(:conflict)
      error -> error
    end
  end

  def validate(_, _, _, _), do: Admission.fail(:conflict)

  defp candidates(catalogue, observation) do
    catalogue.profiles
    |> Enum.filter(&matches?(&1, observation))
    |> Enum.map(fn profile ->
      %{
        profile: profile,
        confidence: profile.confidence,
        reasons: ["all_declared_predicates_matched"]
      }
    end)
  end

  defp matches?(profile, observation) do
    Enum.all?(profile.fingerprints, &Predicate.evaluate_admitted(&1, observation))
  end

  defp choose([]), do: {:unknown, :no_match, nil, nil}

  defp choose(candidates) do
    eligible = Enum.filter(candidates, &(&1.confidence in [:exact, :strong]))
    best = Enum.max(Enum.map(eligible, &@rank[&1.confidence]), fn -> 0 end)

    case Enum.filter(eligible, &(@rank[&1.confidence] == best)) do
      [] ->
        {:unknown, :insufficient_evidence, nil, nil}

      [%{profile: selected, confidence: confidence}] ->
        {:resolved, :unique_best_match, selected, confidence}

      _ ->
        {:ambiguous, :equal_best_matches, nil, nil}
    end
  end

  defp diagnostic(candidate) do
    %{
      profile: {candidate.profile.id, candidate.profile.version},
      decoder: candidate.profile.decoder,
      confidence: candidate.confidence,
      reasons: candidate.reasons
    }
  end

  defp build(candidates, catalogue, observation_identity, probe_evidence) do
    {status, reason, selected, confidence} = choose(candidates)

    %__MODULE__{
      status: status,
      reason: reason,
      selected: selected,
      confidence: confidence,
      candidates: Enum.map(candidates, &diagnostic/1),
      catalogue_identity: catalogue.identity,
      observation_identity: observation_identity,
      probe_evidence: probe_evidence
    }
  end

  defp passive_candidate(candidates, profile) do
    if Enum.any?(candidates, &(&1.profile === profile)),
      do: :ok,
      else: Admission.fail(:conflict)
  end

  defp apply_probe(candidates, evidence, true) do
    Enum.map(candidates, fn candidate ->
      if candidate.profile === evidence.profile do
        %{
          candidate
          | confidence: ProbeContract.promotion(evidence.contract),
            reasons: candidate.reasons ++ ["declared_active_probe_matched"]
        }
      else
        candidate
      end
    end)
  end

  defp apply_probe(candidates, evidence, false) do
    case ProbeContract.mismatch(evidence.contract) do
      :reject ->
        Enum.reject(candidates, &(&1.profile === evidence.profile))

      :uninformative ->
        Enum.map(candidates, &mark_uninformative(&1, evidence.profile))
    end
  end

  defp mark_uninformative(%{profile: profile} = candidate, profile) do
    %{candidate | reasons: candidate.reasons ++ ["declared_active_probe_uninformative"]}
  end

  defp mark_uninformative(candidate, _profile), do: candidate
end
