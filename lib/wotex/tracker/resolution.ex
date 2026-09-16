defmodule Wotex.Tracker.Resolution do
  @moduledoc """
  Pure deterministic resolution bound to one admitted observation and catalogue.
  Exact/strong ties remain ambiguous. Candidate-only matches remain unknown.
  Names, catalogue order and decoder behavior never select a winner.
  """

  alias Wotex.Tracker.{Admission, Catalogue, DeviceProfile, Error, Limits, Observation, Predicate}

  @rank %{exact: 3, strong: 2, candidate: 1, unknown: 0}
  @type t :: %__MODULE__{
          status: :resolved | :unknown | :ambiguous,
          reason: atom(),
          selected: DeviceProfile.t() | nil,
          candidates: [map()],
          catalogue_identity: String.t(),
          observation_identity: String.t()
        }
  @enforce_keys ~w(status reason selected candidates catalogue_identity observation_identity)a
  defstruct @enforce_keys

  @doc "Resolves all admitted profiles without invoking any decoder."
  @spec resolve(term(), term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def resolve(observation, catalogue, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         {:ok, observation} <- Observation.validate(observation, options),
         {:ok, catalogue} <- Catalogue.validate(catalogue, options),
         {:ok, observation_identity} <- Observation.identity(observation, options),
         candidates = Enum.filter(catalogue.profiles, &matches?(&1, observation)),
         :ok <- Admission.bounded_list(candidates, limits.max_candidates) do
      {status, reason, selected} = choose(candidates)

      {:ok,
       %__MODULE__{
         status: status,
         reason: reason,
         selected: selected,
         candidates: Enum.map(candidates, &diagnostic/1),
         catalogue_identity: catalogue.identity,
         observation_identity: observation_identity
       }}
    end
  end

  @doc "Recomputes resolution to reject forged results and changed snapshot inputs."
  @spec validate(term(), term(), term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(value, observation, catalogue, options \\ []) do
    with {:ok, resolution} <- resolve(observation, catalogue, options),
         true <- resolution === value do
      {:ok, resolution}
    else
      false -> Admission.fail(:conflict)
      error -> error
    end
  end

  defp matches?(profile, observation) do
    Enum.all?(profile.fingerprints, &Predicate.evaluate_admitted(&1, observation))
  end

  defp choose([]), do: {:unknown, :no_match, nil}

  defp choose(candidates) do
    eligible = Enum.filter(candidates, &(&1.confidence in [:exact, :strong]))
    best = Enum.max(Enum.map(eligible, &@rank[&1.confidence]), fn -> 0 end)

    case Enum.filter(eligible, &(@rank[&1.confidence] == best)) do
      [] -> {:unknown, :insufficient_evidence, nil}
      [selected] -> {:resolved, :unique_best_match, selected}
      _ -> {:ambiguous, :equal_best_matches, nil}
    end
  end

  defp diagnostic(profile) do
    %{
      profile: {profile.id, profile.version},
      decoder: profile.decoder,
      confidence: profile.confidence,
      reasons: ["all_declared_predicates_matched"]
    }
  end
end
