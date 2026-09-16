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
  @decision_fields ~w(schema request_id severity purpose maximum_cost_class maximum_power_class required_acknowledgement acknowledgement selected qualified_count candidates policy_revision policy_identity evaluated_at status reason action decision_identity)
  @serialized_policy_fields ~w(schema algorithm id revision fact_policy_revision ordinary_order critical_order maximum_fact_age_ms future_skew_ms ordinary_max_cost_class critical_max_cost_class ordinary_max_power_class critical_max_power_class ordinary_acknowledgement critical_acknowledgement ordinary_no_route critical_no_route identity)
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

  @doc "Projects a validated policy to its closed native-JSON representation."
  @spec to_map(term(), term()) :: {:ok, map()} | {:error, Error.t()}
  def to_map(policy, options \\ []) do
    with {:ok, policy} <- validate(policy, options) do
      {:ok, Map.put(policy_map(policy), "identity", policy.identity)}
    end
  end

  @doc "Restores and revalidates a policy from its closed native-JSON representation."
  @spec from_map(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(document, options \\ []) do
    with true <-
           is_map(document) and not is_struct(document) and
             Enum.sort(Map.keys(document)) == Enum.sort(@serialized_policy_fields),
         true <-
           document["schema"] == "wtr.transport-policy.v1" and
             document["algorithm"] == "evidence-budget-ack-preference-v1",
         {:ok, ordinary_acknowledgement} <-
           acknowledgement_atom(document["ordinary_acknowledgement"]),
         {:ok, critical_acknowledgement} <-
           acknowledgement_atom(document["critical_acknowledgement"]),
         {:ok, ordinary_no_route} <- no_route_atom(document["ordinary_no_route"]),
         {:ok, critical_no_route} <- no_route_atom(document["critical_no_route"]),
         {:ok, policy} <-
           new(
             %{
               id: document["id"],
               revision: document["revision"],
               fact_policy_revision: document["fact_policy_revision"],
               ordinary_order: document["ordinary_order"],
               critical_order: document["critical_order"],
               maximum_fact_age_ms: document["maximum_fact_age_ms"],
               future_skew_ms: document["future_skew_ms"],
               ordinary_max_cost_class: document["ordinary_max_cost_class"],
               critical_max_cost_class: document["critical_max_cost_class"],
               ordinary_max_power_class: document["ordinary_max_power_class"],
               critical_max_power_class: document["critical_max_power_class"],
               ordinary_acknowledgement: ordinary_acknowledgement,
               critical_acknowledgement: critical_acknowledgement,
               ordinary_no_route: ordinary_no_route,
               critical_no_route: critical_no_route
             },
             options
           ),
         true <- policy.identity == document["identity"] do
      {:ok, policy}
    else
      false -> Admission.fail(:conflict)
      error -> error
    end
  end

  @doc "Revalidates a closed decision, its policy binding and content identity."
  @spec validate_decision(term(), term(), term()) :: {:ok, map()} | {:error, Error.t()}
  def validate_decision(value, policy, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         {:ok, policy} <- validate(policy, options),
         true <-
           is_map(value) and not is_struct(value) and
             Enum.sort(Map.keys(value)) == Enum.sort(@decision_fields),
         :ok <- Admission.object(value, limits),
         :ok <- decision_shape(value, policy, limits),
         {:ok, identity} <-
           Admission.digest(Map.delete(value, "decision_identity"), Limits.json(limits)),
         true <- identity == value["decision_identity"] do
      {:ok, value}
    else
      false -> Admission.fail(:conflict)
      error -> error
    end
  end

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

  defp decision_shape(value, policy, limits) do
    with true <- value["schema"] == "wtr.transport-decision.v1",
         :ok <-
           Admission.each(
             [
               value["request_id"],
               value["policy_revision"],
               value["policy_identity"],
               value["reason"],
               value["action"],
               value["decision_identity"]
             ],
             &Admission.id(&1, limits)
           ),
         true <- value["policy_revision"] == policy.revision,
         true <- value["policy_identity"] == policy.identity,
         true <- value["severity"] in ~w(ordinary critical),
         true <- value["purpose"] in ~w(telemetry event physical_action),
         true <- class?(value["maximum_cost_class"]),
         true <- class?(value["maximum_power_class"]),
         true <-
           value["required_acknowledgement"] in Enum.map(@acknowledgements, &Atom.to_string/1),
         true <-
           value["required_acknowledgement"] ==
             decision_acknowledgement(policy, value["severity"]),
         true <- is_integer(value["evaluated_at"]),
         true <-
           is_integer(value["qualified_count"]) and
             value["qualified_count"] in 0..limits.max_sources,
         :ok <- Admission.bounded_list(value["candidates"], limits.max_sources),
         true <- Enum.all?(value["candidates"], &candidate_entry?(&1, limits)),
         true <- unique_candidate_ids?(value["candidates"]),
         true <-
           value["qualified_count"] ==
             Enum.count(value["candidates"], &(&1["status"] == "eligible")),
         true <- acknowledgement_decision?(value["acknowledgement"], limits),
         true <- acknowledgement_matches_policy?(value, policy),
         true <- selected_decision?(value["selected"], limits),
         true <- selected_matches_ledger?(value["selected"], value["candidates"]),
         true <- outcome_shape?(value) do
      :ok
    else
      false -> Admission.fail(:invalid_input)
      error -> error
    end
  end

  defp acknowledgement_decision?(nil, _limits), do: true

  defp acknowledgement_decision?(value, limits) when is_map(value) do
    Enum.sort(Map.keys(value)) == Enum.sort(~w(delivery_id candidate_id layer status)) and
      Enum.all?([value["delivery_id"], value["candidate_id"]], fn id ->
        match?(:ok, Admission.id(id, limits))
      end) and
      value["layer"] in Enum.map(TransportCandidate.acknowledgement_layers(), &Atom.to_string/1) and
      value["status"] in ~w(pending acknowledged failed unknown)
  end

  defp acknowledgement_decision?(_, _), do: false

  defp acknowledgement_matches_policy?(%{"acknowledgement" => nil}, _policy), do: true

  defp acknowledgement_matches_policy?(value, policy) do
    value["required_acknowledgement"] != "none" and
      value["acknowledgement"]["candidate_id"] in decision_route_order(policy, value["severity"])
  end

  defp selected_decision?(nil, _limits), do: true

  defp selected_decision?(value, limits) when is_map(value) do
    Enum.sort(Map.keys(value)) ==
      Enum.sort(
        ~w(candidate_id candidate_identity bearer application_protocol cost_class power_class acknowledgement_layers)
      ) and
      Enum.all?(
        [
          value["candidate_id"],
          value["candidate_identity"],
          value["bearer"],
          value["application_protocol"]
        ],
        fn id -> match?(:ok, Admission.id(id, limits)) end
      ) and
      class?(value["cost_class"]) and class?(value["power_class"]) and
      is_list(value["acknowledgement_layers"]) and
      Enum.uniq(value["acknowledgement_layers"]) == value["acknowledgement_layers"] and
      Enum.all?(
        value["acknowledgement_layers"],
        &(&1 in Enum.map(TransportCandidate.acknowledgement_layers(), fn layer ->
            Atom.to_string(layer)
          end))
      )
  end

  defp selected_decision?(_, _), do: false

  defp candidate_entry?(value, limits) when is_map(value) do
    keys = Map.keys(value) |> Enum.sort()
    missing = Enum.sort(~w(candidate_id preference_rank status reason))

    present =
      Enum.sort(
        ~w(candidate_id candidate_identity bearer application_protocol cost_class power_class acknowledgement_layers capability_fact_identity connectivity_fact_identity preference_rank status reason)
      )

    case keys do
      ^missing -> missing_candidate_entry?(value, limits)
      ^present -> present_candidate_entry?(value, limits)
      _ -> false
    end
  end

  defp candidate_entry?(_, _), do: false

  defp missing_candidate_entry?(value, limits),
    do:
      id?(value["candidate_id"], limits) and rank?(value["preference_rank"]) and
        value["status"] == "rejected" and value["reason"] == "candidate_missing"

  defp present_candidate_entry?(value, limits) do
    identifiers =
      ~w(candidate_id candidate_identity bearer application_protocol capability_fact_identity connectivity_fact_identity reason)

    Enum.all?(identifiers, &id?(value[&1], limits)) and class?(value["cost_class"]) and
      class?(value["power_class"]) and optional_rank?(value["preference_rank"]) and
      value["status"] in ~w(eligible rejected) and
      acknowledgement_layer_strings?(value["acknowledgement_layers"])
  end

  defp optional_rank?(nil), do: true
  defp optional_rank?(value), do: rank?(value)
  defp rank?(value), do: is_integer(value) and value >= 0

  defp selected_matches_ledger?(nil, _candidates), do: true

  defp selected_matches_ledger?(selected, candidates) do
    projection =
      ~w(candidate_id candidate_identity bearer application_protocol cost_class power_class acknowledgement_layers)

    Enum.any?(candidates, fn candidate ->
      candidate["status"] == "eligible" and Map.take(candidate, projection) == selected
    end)
  end

  defp acknowledgement_layer_strings?(values) when is_list(values) do
    admitted = Enum.map(TransportCandidate.acknowledgement_layers(), &Atom.to_string/1)
    Enum.uniq(values) == values and Enum.all?(values, &(&1 in admitted))
  end

  defp acknowledgement_layer_strings?(_), do: false

  defp id?(value, limits), do: match?(:ok, Admission.id(value, limits))

  defp outcome_shape?(%{"status" => "selected", "action" => "send", "selected" => selected}),
    do: is_map(selected)

  defp outcome_shape?(%{
         "status" => "deferred",
         "action" => "store_and_retry",
         "selected" => nil
       }),
       do: true

  defp outcome_shape?(%{"status" => "unavailable", "action" => "unavailable", "selected" => nil}),
    do: true

  defp outcome_shape?(%{
         "status" => "acknowledged",
         "action" => "none",
         "selected" => nil,
         "acknowledgement" => acknowledgement
       }),
       do: is_map(acknowledgement)

  defp outcome_shape?(%{
         "status" => "pending",
         "action" => "wait",
         "selected" => nil,
         "acknowledgement" => acknowledgement
       }),
       do: is_map(acknowledgement)

  defp outcome_shape?(%{
         "status" => "unknown",
         "action" => "hold",
         "selected" => nil,
         "acknowledgement" => acknowledgement
       }),
       do: is_map(acknowledgement)

  defp outcome_shape?(_), do: false

  defp unique_candidate_ids?(candidates) do
    ids = Enum.map(candidates, &Map.get(&1, "candidate_id"))
    Enum.all?(ids, &is_binary/1) and Enum.uniq(ids) == ids
  end

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

  defp decision_acknowledgement(policy, "ordinary"),
    do: Atom.to_string(policy.ordinary_acknowledgement)

  defp decision_acknowledgement(policy, "critical"),
    do: Atom.to_string(policy.critical_acknowledgement)

  defp decision_acknowledgement(_policy, _severity), do: nil

  defp decision_route_order(policy, "ordinary"), do: policy.ordinary_order
  defp decision_route_order(policy, "critical"), do: policy.critical_order
  defp decision_route_order(_policy, _severity), do: []

  defp acknowledgement_atom("none"), do: {:ok, :none}
  defp acknowledgement_atom("radio"), do: {:ok, :radio}
  defp acknowledgement_atom("network"), do: {:ok, :network}
  defp acknowledgement_atom("transport"), do: {:ok, :transport}
  defp acknowledgement_atom("application"), do: {:ok, :application}
  defp acknowledgement_atom("durable_admission"), do: {:ok, :durable_admission}
  defp acknowledgement_atom(_), do: Admission.fail(:invalid_input)

  defp no_route_atom("store_and_retry"), do: {:ok, :store_and_retry}
  defp no_route_atom("unavailable"), do: {:ok, :unavailable}
  defp no_route_atom(_), do: Admission.fail(:invalid_input)

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
