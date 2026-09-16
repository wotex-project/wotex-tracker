defmodule Wotex.Tracker.TransportPolicy do
  @moduledoc """
  Deterministic transport selection from explicit route facts and budgets.

  Policy order is deployment-specific. Capability and connectivity must both be
  fresh true facts; false, unknown and stale inputs never become availability.
  Acknowledgements name their exact layer. Unknown or pending acknowledgement
  holds the decision and never causes an automatic retry.
  """
  alias Wotex.Tracker.{Admission, Error, Limits, TransportCandidate}

  @fields ~w(id revision fact_policy_revision ordinary_order critical_order maximum_fact_age_ms future_skew_ms ordinary_max_cost_class critical_max_cost_class ordinary_max_power_class critical_max_power_class ordinary_acknowledgement critical_acknowledgement ordinary_no_route critical_no_route)a
  @acknowledgements [:none | TransportCandidate.acknowledgement_layers()]
  @no_route ~w(store_and_retry unavailable)a
  @request_fields ~w(id severity purpose maximum_cost_class maximum_power_class acknowledgement)a
  @acknowledgement_fields ~w(delivery_id candidate_id layer status)a
  @type t :: %__MODULE__{}
  @enforce_keys @fields ++ [:identity]
  defstruct @enforce_keys

  @doc "Admits route order, fact freshness, budgets and acknowledgement requirements."
  @spec new(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(input, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         :ok <- Admission.fields(input, @fields),
         :ok <-
           Admission.each(
             [input.id, input.revision, input.fact_policy_revision],
             &Admission.id(&1, limits)
           ),
         :ok <- route(input.ordinary_order, limits),
         :ok <- route(input.critical_order, limits),
         true <- duration?(input.maximum_fact_age_ms) and duration?(input.future_skew_ms),
         true <-
           Enum.all?(
             [
               input.ordinary_max_cost_class,
               input.critical_max_cost_class,
               input.ordinary_max_power_class,
               input.critical_max_power_class
             ],
             &class?/1
           ),
         true <-
           input.ordinary_acknowledgement in @acknowledgements and
             input.critical_acknowledgement in @acknowledgements,
         true <- input.ordinary_no_route in @no_route and input.critical_no_route in @no_route,
         {:ok, identity} <- Admission.digest(policy_map(input), Limits.json(limits)) do
      {:ok, struct!(__MODULE__, Map.put(input, :identity, identity))}
    else
      false -> Admission.fail(:invalid_input)
      error -> error
    end
  end

  @doc "Rejects a changed route table, evidence revision, budget or fallback."
  @spec validate(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(value, options \\ [])

  def validate(%__MODULE__{} = policy, options) do
    with {:ok, admitted} <- new(Map.take(policy, @fields), options) do
      if admitted === policy, do: {:ok, admitted}, else: Admission.fail(:conflict)
    end
  end

  def validate(_, _), do: Admission.fail(:invalid_input)

  @doc "Selects a route, holds an uncertain acknowledgement, or returns the declared fallback."
  @spec select(term(), term(), term(), integer(), term()) ::
          {:ok, map()} | {:error, Error.t()}
  def select(candidates, request, policy, now, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         :ok <- Admission.bounded_list(candidates, limits.max_sources),
         {:ok, policy} <- validate(policy, options),
         {:ok, request} <- request(request, policy, limits),
         true <- is_integer(now),
         {:ok, candidates} <- candidates(candidates, options),
         {:ok, result} <- decide(candidates, request, policy, now, limits) do
      {:ok, result}
    else
      false -> Admission.fail(:invalid_input)
      error -> error
    end
  end

  defp request(input, policy, limits) do
    with :ok <- Admission.fields(input, @request_fields),
         :ok <- Admission.id(input.id, limits),
         true <- input.severity in [:ordinary, :critical],
         true <- input.purpose in [:telemetry, :event, :physical_action],
         true <- class?(input.maximum_cost_class) and class?(input.maximum_power_class),
         {:ok, acknowledgement} <-
           acknowledgement(input.acknowledgement, input.severity, policy, limits) do
      {:ok, Map.put(input, :acknowledgement, acknowledgement)}
    else
      false -> Admission.fail(:invalid_input)
      error -> error
    end
  end

  defp acknowledgement(nil, _severity, _policy, _limits), do: {:ok, nil}

  defp acknowledgement(value, severity, policy, limits) do
    required = required_acknowledgement(policy, severity)

    with :ok <- Admission.fields(value, @acknowledgement_fields),
         :ok <-
           Admission.each([value.delivery_id, value.candidate_id], &Admission.id(&1, limits)),
         true <- value.layer in TransportCandidate.acknowledgement_layers(),
         true <- value.status in [:pending, :acknowledged, :failed, :unknown],
         true <- required != :none,
         true <- value.candidate_id in route_order(policy, severity) do
      {:ok, value}
    else
      false -> Admission.fail(:conflict)
      error -> error
    end
  end

  defp candidates(values, options) do
    Enum.reduce_while(values, {:ok, %{}}, fn value, {:ok, admitted} ->
      case admit_candidate(value, admitted, options) do
        {:ok, next} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end

  defp admit_candidate(value, admitted, options) do
    with {:ok, candidate} <- TransportCandidate.validate(value, options),
         false <- Map.has_key?(admitted, candidate.id) do
      {:ok, Map.put(admitted, candidate.id, candidate)}
    else
      true -> Admission.fail(:duplicate_id)
      error -> error
    end
  end

  defp decide(candidates, request, policy, now, limits) do
    order = route_order(policy, request.severity)
    failed = failed_candidate(request.acknowledgement)

    ledger =
      order
      |> Enum.with_index()
      |> Enum.map(fn {id, rank} ->
        route_entry(Map.get(candidates, id), id, rank, failed, request, policy, now)
      end)
      |> Kernel.++(unlisted_entries(candidates, order))

    eligible = Enum.filter(ledger, &(&1["status"] == "eligible"))
    selected = List.first(eligible)

    base = %{
      "schema" => "wtr.transport-decision.v1",
      "request_id" => request.id,
      "severity" => Atom.to_string(request.severity),
      "purpose" => Atom.to_string(request.purpose),
      "maximum_cost_class" => request.maximum_cost_class,
      "maximum_power_class" => request.maximum_power_class,
      "required_acknowledgement" =>
        policy |> required_acknowledgement(request.severity) |> Atom.to_string(),
      "acknowledgement" => acknowledgement_map(request.acknowledgement),
      "selected" => selected && selected_candidate(selected),
      "qualified_count" => length(eligible),
      "candidates" => ledger,
      "policy_revision" => policy.revision,
      "policy_identity" => policy.identity,
      "evaluated_at" => now
    }

    outcome = outcome(base, selected, request, policy)

    with {:ok, identity} <- Admission.digest(outcome, Limits.json(limits)) do
      {:ok, Map.put(outcome, "decision_identity", identity)}
    end
  end

  defp route_entry(nil, id, rank, _failed, _request, _policy, _now),
    do: %{
      "candidate_id" => id,
      "preference_rank" => rank,
      "status" => "rejected",
      "reason" => "candidate_missing"
    }

  defp route_entry(candidate, id, rank, failed, request, policy, now) do
    reason = rejection(candidate, id, failed, request, policy, now)

    %{
      "candidate_id" => id,
      "candidate_identity" => candidate.identity,
      "bearer" => candidate.bearer,
      "application_protocol" => candidate.application_protocol,
      "cost_class" => candidate.cost_class,
      "power_class" => candidate.power_class,
      "acknowledgement_layers" => Enum.map(candidate.acknowledgement_layers, &Atom.to_string/1),
      "capability_fact_identity" => candidate.capability.identity,
      "connectivity_fact_identity" => candidate.connectivity.identity,
      "preference_rank" => rank,
      "status" => if(reason == nil, do: "eligible", else: "rejected"),
      "reason" => reason || "eligible"
    }
  end

  defp rejection(candidate, id, failed, request, policy, now) do
    [
      failed_rejection(id, failed),
      revision_rejection(candidate, policy),
      fact_rejection(candidate, policy, now),
      budget_rejection(candidate, request, policy),
      support_rejection(candidate, request, policy)
    ]
    |> Enum.find(&is_binary/1)
  end

  defp failed_rejection(id, id), do: "acknowledgement_failed"
  defp failed_rejection(_, _), do: nil

  defp revision_rejection(candidate, policy) do
    cond do
      candidate.capability.policy_revision != policy.fact_policy_revision ->
        "capability_revision"

      candidate.connectivity.policy_revision != policy.fact_policy_revision ->
        "connectivity_revision"

      true ->
        nil
    end
  end

  defp fact_rejection(candidate, policy, now) do
    capability = fact_truth(candidate.capability, policy, now)
    connectivity = fact_truth(candidate.connectivity, policy, now)

    cond do
      capability != "true" -> "capability:" <> capability
      connectivity != "true" -> "connectivity:" <> connectivity
      true -> nil
    end
  end

  defp budget_rejection(candidate, request, policy) do
    {policy_cost, policy_power} = policy_budgets(policy, request.severity)

    cond do
      candidate.cost_class > min(policy_cost, request.maximum_cost_class) -> "cost_budget"
      candidate.power_class > min(policy_power, request.maximum_power_class) -> "power_budget"
      true -> nil
    end
  end

  defp support_rejection(candidate, request, policy) do
    required = required_acknowledgement(policy, request.severity)

    if required != :none and required not in candidate.acknowledgement_layers,
      do: "acknowledgement_unsupported",
      else: nil
  end

  defp unlisted_entries(candidates, order) do
    candidates
    |> Map.values()
    |> Enum.reject(&(&1.id in order))
    |> Enum.sort_by(& &1.id)
    |> Enum.map(fn candidate ->
      %{
        "candidate_id" => candidate.id,
        "candidate_identity" => candidate.identity,
        "bearer" => candidate.bearer,
        "application_protocol" => candidate.application_protocol,
        "cost_class" => candidate.cost_class,
        "power_class" => candidate.power_class,
        "acknowledgement_layers" => Enum.map(candidate.acknowledgement_layers, &Atom.to_string/1),
        "capability_fact_identity" => candidate.capability.identity,
        "connectivity_fact_identity" => candidate.connectivity.identity,
        "preference_rank" => nil,
        "status" => "rejected",
        "reason" => "not_preferred"
      }
    end)
  end

  defp outcome(base, _selected, request, policy) when not is_nil(request.acknowledgement) do
    acknowledgement_outcome(base, request, policy)
  end

  defp outcome(base, nil, request, policy) do
    no_route = no_route(policy, request.severity)

    Map.merge(base, %{
      "status" => if(no_route == :store_and_retry, do: "deferred", else: "unavailable"),
      "reason" => "no_eligible_transport",
      "action" => Atom.to_string(no_route)
    })
  end

  defp outcome(base, _selected, _request, _policy),
    do:
      Map.merge(base, %{
        "status" => "selected",
        "reason" => "deterministic_preference",
        "action" => "send"
      })

  defp acknowledgement_outcome(base, request, policy) do
    acknowledgement = request.acknowledgement
    required = required_acknowledgement(policy, request.severity)

    case {acknowledgement.status, acknowledgement.layer == required} do
      {:acknowledged, true} ->
        terminal(base, "acknowledged", "required_acknowledgement_received", "none")

      {:failed, _} ->
        if base["selected"],
          do: terminal(base, "selected", "fallback_after_failed_acknowledgement", "send"),
          else:
            outcome(
              Map.put(base, "acknowledgement", acknowledgement_map(acknowledgement)),
              nil,
              %{request | acknowledgement: nil},
              policy
            )

      {:pending, _} ->
        terminal(base, "pending", "acknowledgement_pending", "wait")

      {:unknown, _} ->
        terminal(base, "unknown", "acknowledgement_unknown", "hold")

      {:acknowledged, false} ->
        terminal(base, "unknown", "acknowledgement_layer_insufficient", "hold")
    end
  end

  defp terminal(base, status, reason, action),
    do:
      Map.merge(base, %{
        "status" => status,
        "reason" => reason,
        "action" => action,
        "selected" => if(action == "send", do: base["selected"], else: nil)
      })

  defp selected_candidate(entry),
    do:
      Map.take(entry, [
        "candidate_id",
        "candidate_identity",
        "bearer",
        "application_protocol",
        "cost_class",
        "power_class",
        "acknowledgement_layers"
      ])

  defp fact_truth(fact, policy, now) do
    age = now - fact.observed_at

    if age < -policy.future_skew_ms or age > policy.maximum_fact_age_ms,
      do: "unknown",
      else: fact.status
  end

  defp acknowledgement_map(nil), do: nil

  defp acknowledgement_map(value),
    do: %{
      "delivery_id" => value.delivery_id,
      "candidate_id" => value.candidate_id,
      "layer" => Atom.to_string(value.layer),
      "status" => Atom.to_string(value.status)
    }

  defp failed_candidate(%{status: :failed, candidate_id: id}), do: id
  defp failed_candidate(_), do: nil

  defp route(values, limits) do
    with :ok <- Admission.ids(values, limits, limits.max_sources),
         true <- values != [] do
      :ok
    else
      false -> Admission.fail(:invalid_input)
      error -> error
    end
  end

  defp route_order(policy, :ordinary), do: policy.ordinary_order
  defp route_order(policy, :critical), do: policy.critical_order

  defp required_acknowledgement(policy, :ordinary), do: policy.ordinary_acknowledgement
  defp required_acknowledgement(policy, :critical), do: policy.critical_acknowledgement

  defp policy_budgets(policy, :ordinary),
    do: {policy.ordinary_max_cost_class, policy.ordinary_max_power_class}

  defp policy_budgets(policy, :critical),
    do: {policy.critical_max_cost_class, policy.critical_max_power_class}

  defp no_route(policy, :ordinary), do: policy.ordinary_no_route
  defp no_route(policy, :critical), do: policy.critical_no_route

  defp class?(value), do: is_integer(value) and value in 0..100
  defp duration?(value), do: is_integer(value) and value in 0..604_800_000

  defp policy_map(input),
    do: %{
      "schema" => "wtr.transport-policy.v1",
      "algorithm" => "evidence-budget-ack-preference-v1",
      "id" => input.id,
      "revision" => input.revision,
      "fact_policy_revision" => input.fact_policy_revision,
      "ordinary_order" => input.ordinary_order,
      "critical_order" => input.critical_order,
      "maximum_fact_age_ms" => input.maximum_fact_age_ms,
      "future_skew_ms" => input.future_skew_ms,
      "ordinary_max_cost_class" => input.ordinary_max_cost_class,
      "critical_max_cost_class" => input.critical_max_cost_class,
      "ordinary_max_power_class" => input.ordinary_max_power_class,
      "critical_max_power_class" => input.critical_max_power_class,
      "ordinary_acknowledgement" => Atom.to_string(input.ordinary_acknowledgement),
      "critical_acknowledgement" => Atom.to_string(input.critical_acknowledgement),
      "ordinary_no_route" => Atom.to_string(input.ordinary_no_route),
      "critical_no_route" => Atom.to_string(input.critical_no_route)
    }
end
