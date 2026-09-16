defmodule Wotex.Tracker.TransportDegradationTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Wotex.Tracker.{
    Evidence,
    EvidenceBundle,
    Fixtures,
    PolicyFact,
    TransportCandidate,
    TransportDegradation,
    TransportPolicy
  }

  test "declared primary health degrades on fallback and recovers deterministically" do
    policy = transport_policy()
    degradation = degradation_policy(policy)
    healthy = decision(policy, "healthy", 1_000, lorawan: "true", cellular: "true")
    fallback = decision(policy, "fallback", 1_001, lorawan: "false", cellular: "true")
    recovered = decision(policy, "recovered", 1_002, lorawan: "true", cellular: "true")

    assert {:ok, baseline} =
             TransportDegradation.evaluate(nil, healthy, degradation, :live, 1_000)

    assert baseline["status"] == "baseline"
    assert baseline["transport_status"] == "healthy"
    assert baseline["candidate_id"] == "lorawan"
    assert baseline["event"] == nil

    assert {:ok, degraded} =
             TransportDegradation.evaluate(
               baseline["state"],
               fallback,
               degradation,
               :live,
               1_001
             )

    assert degraded["status"] == "transition"
    assert degraded["transport_status"] == "degraded"
    assert degraded["candidate_id"] == "cellular"
    assert degraded["event"]["kind"] == "transport.degraded"
    assert degraded["event"]["from_candidate_id"] == "lorawan"
    assert degraded["event"]["to_candidate_id"] == "cellular"
    assert degraded["physical_action_dispatch"] == "separate_authorization_required"

    assert {:ok, ^degraded} =
             TransportDegradation.validate_transition(baseline["state"], degraded)

    assert :ok = TransportDegradation.validate_event(degraded["event"])

    assert {:ok, recovery} =
             TransportDegradation.evaluate(
               degraded["state"],
               recovered,
               degradation,
               :live,
               1_002
             )

    assert recovery["transport_status"] == "healthy"
    assert recovery["event"]["kind"] == "transport.recovered"
    assert recovery["event"]["from_candidate_id"] == "cellular"
    assert recovery["event"]["to_candidate_id"] == "lorawan"

    assert {:ok, document} = TransportDegradation.state_to_map(recovery["state"])
    assert {:ok, restored} = TransportDegradation.state_from_map(document)
    assert restored === recovery["state"]
    assert {:ok, transport_document} = TransportPolicy.to_map(policy)
    assert TransportPolicy.from_map(transport_document) == {:ok, policy}
  end

  test "no route degrades while uncertain acknowledgement remains unknown" do
    policy = transport_policy()
    degradation = degradation_policy(policy)
    healthy = decision(policy, "healthy", 1_000, lorawan: "true", cellular: "true")
    {:ok, baseline} = TransportDegradation.evaluate(nil, healthy, degradation, :replay, 1_000)

    unavailable = decision(policy, "unavailable", 1_001, candidates: [])

    assert {:ok, degraded} =
             TransportDegradation.evaluate(
               baseline["state"],
               unavailable,
               degradation,
               :replay,
               1_001
             )

    assert degraded["transport_status"] == "degraded"
    assert degraded["reason"] == "no_eligible_transport"
    assert degraded["event"]["kind"] == "transport.degraded"
    assert degraded["physical_action_dispatch"] == "prohibited"

    pending =
      decision(policy, "pending", 1_002,
        lorawan: "true",
        cellular: "true",
        acknowledgement: acknowledgement(:pending)
      )

    assert {:ok, uncertain} =
             TransportDegradation.evaluate(
               degraded["state"],
               pending,
               degradation,
               :live,
               1_002
             )

    assert uncertain["status"] == "baseline"
    assert uncertain["transport_status"] == "unknown"
    assert uncertain["reason"] == "acknowledgement_pending"
    assert uncertain["event"] == nil
  end

  test "an exact required acknowledgement classifies its named candidate" do
    policy = transport_policy()
    degradation = degradation_policy(policy)

    acknowledged =
      decision(policy, "acknowledged", 1_000,
        lorawan: "true",
        cellular: "true",
        acknowledgement: acknowledgement(:acknowledged)
      )

    assert acknowledged["selected"] == nil

    assert {:ok, result} =
             TransportDegradation.evaluate(nil, acknowledged, degradation, :live, 1_000)

    assert result["transport_status"] == "healthy"
    assert result["candidate_id"] == "lorawan"
  end

  test "decision freshness has exact future and age boundaries" do
    policy = transport_policy()

    degradation =
      degradation_policy(policy, %{maximum_decision_age_ms: 10, future_skew_ms: 5})

    decision = decision(policy, "freshness", 1_000, lorawan: "true", cellular: "true")

    for {now, expected, reason} <- [
          {995, "healthy", "healthy_candidate"},
          {994, "unknown", "decision_in_future"},
          {1_010, "healthy", "healthy_candidate"},
          {1_011, "unknown", "decision_stale"}
        ] do
      assert {:ok, result} =
               TransportDegradation.evaluate(nil, decision, degradation, :live, now)

      assert result["transport_status"] == expected
      assert result["reason"] == reason
    end
  end

  test "duplicate and historical decisions cannot replace a newer canonical decision" do
    policy = transport_policy()
    degradation = degradation_policy(policy)
    first = decision(policy, "first", 1_000, lorawan: "true", cellular: "true")
    latest = decision(policy, "latest", 1_002, lorawan: "false", cellular: "true")
    historical = decision(policy, "historical", 1_001, lorawan: "true", cellular: "true")
    {:ok, baseline} = TransportDegradation.evaluate(nil, first, degradation, :live, 1_000)

    {:ok, advanced} =
      TransportDegradation.evaluate(baseline["state"], latest, degradation, :live, 1_002)

    assert {:ok, duplicate} =
             TransportDegradation.evaluate(
               advanced["state"],
               latest,
               degradation,
               :live,
               1_002
             )

    assert duplicate["decision_outcome"] == "duplicate"
    assert duplicate["event"] == nil

    assert {:ok, retained} =
             TransportDegradation.evaluate(
               advanced["state"],
               historical,
               degradation,
               :live,
               1_003
             )

    assert retained["decision_outcome"] == "historical"
    assert retained["decision_identity"] == latest["decision_identity"]
    assert retained["transport_status"] == "degraded"

    assert {:ok, regressed} =
             TransportDegradation.evaluate(
               advanced["state"],
               nil,
               degradation,
               :live,
               1_001
             )

    assert regressed["status"] == "unknown"
    assert regressed["reason"] == "clock_regressed"
    assert regressed["state"] === advanced["state"]
  end

  test "rule edits emit recomputation without changing the underlying decision" do
    transport = transport_policy()
    original = degradation_policy(transport, %{healthy_candidate_ids: ["lorawan", "cellular"]})

    edited =
      degradation_policy(transport, %{revision: "health-v2", healthy_candidate_ids: ["lorawan"]})

    fallback = decision(transport, "fallback", 1_000, lorawan: "false", cellular: "true")
    {:ok, baseline} = TransportDegradation.evaluate(nil, fallback, original, :live, 1_000)
    assert baseline["transport_status"] == "healthy"

    assert {:ok, live} =
             TransportDegradation.evaluate(
               baseline["state"],
               fallback,
               edited,
               :live,
               1_000
             )

    assert {:ok, replay} =
             TransportDegradation.evaluate(
               baseline["state"],
               fallback,
               edited,
               :replay,
               1_000
             )

    assert live["status"] == "recomputed"
    assert live["transport_status"] == "degraded"
    assert live["event"]["kind"] == "transport.recomputed"
    assert live["event"] === replay["event"]
    assert live["state"] === replay["state"]
    assert replay["physical_action_dispatch"] == "prohibited"
  end

  test "decision, policy and state validation reject content mutation" do
    transport = transport_policy()
    policy = degradation_policy(transport)
    decision = decision(transport, "validated", 1_000, lorawan: "true", cellular: "true")
    assert {:ok, ^decision} = TransportPolicy.validate_decision(decision, transport)

    for changed <- [
          Map.put(decision, "reason", "changed"),
          Map.put(decision, "policy_identity", "changed"),
          Map.put(decision, "extra", true),
          Map.put(decision, "selected", nil),
          put_in(decision, ["candidates", Access.at(0), "extra"], true),
          Map.put(decision, "qualified_count", 0),
          put_in(decision, ["selected", "candidate_id"], "cellular")
        ] do
      assert {:error, _} = TransportPolicy.validate_decision(changed, transport)
    end

    pending =
      decision(transport, "pending-validation", 1_001,
        lorawan: "true",
        cellular: "true",
        acknowledgement: acknowledgement(:pending)
      )

    assert {:error, _} =
             TransportPolicy.validate_decision(
               Map.put(pending, "acknowledgement", nil),
               transport
             )

    assert {:ok, %{"state" => state}} =
             TransportDegradation.evaluate(nil, decision, policy, :live, 1_000)

    assert {:ok, ^state} = TransportDegradation.validate_state(state)

    assert {:error, %{code: :conflict}} =
             TransportDegradation.validate_state(%{state | status: "degraded"})

    for change <- [
          %{healthy_candidate_ids: []},
          %{healthy_candidate_ids: ["missing"]},
          %{maximum_decision_age_ms: -1},
          %{future_skew_ms: 604_800_001},
          %{extra: true}
        ] do
      assert {:error, _} = TransportDegradation.new(Map.merge(policy_input(transport), change))
    end

    assert {:error, _} = TransportDegradation.validate(:invalid)
    assert {:error, _} = TransportDegradation.validate_state(:invalid)

    assert {:error, _} =
             TransportDegradation.evaluate(nil, decision, policy, :invalid, 1_000)

    assert {:ok, document} = TransportDegradation.state_to_map(state)

    for changed <- [
          Map.put(document, "status", "degraded"),
          Map.put(document, "identity", "changed"),
          put_in(document, ["policy", "identity"], "changed"),
          put_in(document, ["policy", "transport_policy", "identity"], "changed"),
          Map.put(document, "extra", true)
        ] do
      assert {:error, _} = TransportDegradation.state_from_map(changed)
    end

    {:ok, fallback} =
      TransportDegradation.evaluate(
        state,
        decision(transport, "fallback-validation", 1_001,
          lorawan: "false",
          cellular: "true"
        ),
        policy,
        :live,
        1_001
      )

    assert {:error, _} =
             TransportDegradation.validate_transition(
               state,
               put_in(fallback, ["event", "reason"], "changed")
             )

    assert {:error, _} =
             TransportDegradation.validate_event(Map.put(fallback["event"], "extra", true))
  end

  property "healthy classification is invariant across candidate input order" do
    check all(reverse? <- boolean()) do
      policy = transport_policy()
      candidates = candidates(lorawan: "true", cellular: "true")
      candidates = if reverse?, do: Enum.reverse(candidates), else: candidates
      request = request("property")
      {:ok, decision} = TransportPolicy.select(candidates, request, policy, 1_000)
      degradation = degradation_policy(policy)
      {:ok, result} = TransportDegradation.evaluate(nil, decision, degradation, :replay, 1_000)
      assert result["transport_status"] == "healthy"
      assert result["candidate_id"] == "lorawan"
    end
  end

  defp decision(policy, id, now, options) do
    candidates = Keyword.get(options, :candidates, candidates(options))
    request = request(id, Keyword.get(options, :acknowledgement))
    {:ok, value} = TransportPolicy.select(candidates, request, policy, now)
    value
  end

  defp request(id, acknowledgement \\ nil),
    do: %{
      id: id,
      severity: :critical,
      purpose: :event,
      maximum_cost_class: 100,
      maximum_power_class: 100,
      acknowledgement: acknowledgement
    }

  defp acknowledgement(status),
    do: %{
      delivery_id: "delivery",
      candidate_id: "lorawan",
      layer: :network,
      status: status
    }

  defp degradation_policy(transport, changes \\ %{}) do
    {:ok, value} = TransportDegradation.new(Map.merge(policy_input(transport), changes))
    value
  end

  defp policy_input(transport),
    do: %{
      id: "transport-health",
      revision: "health-v1",
      transport_policy: transport,
      healthy_candidate_ids: ["lorawan"],
      maximum_decision_age_ms: 1_000,
      future_skew_ms: 0
    }

  defp transport_policy do
    {:ok, value} =
      TransportPolicy.new(%{
        id: "bike-transport",
        revision: "transport-v1",
        fact_policy_revision: "facts-v1",
        ordinary_order: ["lorawan"],
        critical_order: ["lorawan", "cellular"],
        maximum_fact_age_ms: 1_000,
        future_skew_ms: 0,
        ordinary_max_cost_class: 50,
        critical_max_cost_class: 100,
        ordinary_max_power_class: 50,
        critical_max_power_class: 100,
        ordinary_acknowledgement: :network,
        critical_acknowledgement: :network,
        ordinary_no_route: :store_and_retry,
        critical_no_route: :unavailable
      })

    value
  end

  defp candidates(options) do
    [
      candidate("lorawan", Keyword.get(options, :lorawan, "true"), 10),
      candidate("cellular", Keyword.get(options, :cellular, "true"), 80)
    ]
  end

  defp candidate(id, connectivity, class) do
    {:ok, value} =
      TransportCandidate.new(%{
        id: id,
        bearer: id,
        application_protocol: "fixture-protocol",
        capability:
          fact(
            "#{id}-capability",
            TransportCandidate.capability_predicate(id),
            "true",
            :capability
          ),
        connectivity:
          fact(
            "#{id}-connectivity-#{connectivity}",
            TransportCandidate.connectivity_predicate(id),
            connectivity,
            :transport
          ),
        cost_class: class,
        power_class: class,
        acknowledgement_layers: [:network]
      })

    value
  end

  defp fact(id, predicate, status, kind) do
    observation = Fixtures.observation(%{id: "capture-#{id}", observed_at: 1_000})

    {:ok, evidence} =
      Evidence.new(%{
        id: id,
        kind: kind,
        claim: %{
          "schema" => "wtr.policy-fact.v1",
          "predicate" => predicate,
          "status" => status,
          "policy_revision" => "facts-v1",
          "reason" => "fixture"
        },
        source_observation_ids: [observation.id],
        evidence_ids: [],
        profile: {"transport", "1"},
        decoder: {"transport", "1"},
        confidence: :exact,
        reasons: ["fixture"],
        association_id: nil
      })

    {:ok, bundle} = EvidenceBundle.new([observation], [evidence])
    {:ok, value} = PolicyFact.new(id, bundle)
    value
  end
end
