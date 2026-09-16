defmodule Wotex.Tracker.TransportPolicyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Wotex.Tracker.{
    Evidence,
    EvidenceBundle,
    Fixtures,
    PolicyFact,
    TransportCandidate,
    TransportPolicy
  }

  test "deployment order selects a bearer while preserving its application protocol" do
    lorawan = candidate("lorawan", bearer: "lorawan-eu868", protocol: "lorawan-uplink")
    cellular = candidate("cellular", bearer: "lte-m", protocol: "teltonika-codec8e")
    policy = policy()

    for candidates <- [[lorawan, cellular], [cellular, lorawan]] do
      assert {:ok, result} = TransportPolicy.select(candidates, request(), policy, 1_000)
      assert result["status"] == "selected"
      assert result["action"] == "send"
      assert result["selected"]["candidate_id"] == "lorawan"
      assert result["selected"]["bearer"] == "lorawan-eu868"
      assert result["selected"]["application_protocol"] == "lorawan-uplink"
      assert result["required_acknowledgement"] == "network"
      assert result["qualified_count"] == 1
    end
  end

  test "ordinary unavailability stores while a critical event may use cellular fallback" do
    lorawan = candidate("lorawan", connectivity: "false")
    cellular = candidate("cellular", cost: 80, power: 80)
    policy = policy()

    assert {:ok, ordinary} =
             TransportPolicy.select([cellular, lorawan], request(), policy, 1_000)

    assert ordinary["status"] == "deferred"
    assert ordinary["action"] == "store_and_retry"
    assert ordinary["selected"] == nil
    assert entry(ordinary, "lorawan")["reason"] == "connectivity:false"
    assert entry(ordinary, "cellular")["reason"] == "not_preferred"

    assert {:ok, critical} =
             TransportPolicy.select(
               [cellular, lorawan],
               request(%{
                 severity: :critical,
                 maximum_cost_class: 100,
                 maximum_power_class: 100
               }),
               policy,
               1_000
             )

    assert critical["status"] == "selected"
    assert critical["selected"]["candidate_id"] == "cellular"
    assert critical["required_acknowledgement"] == "durable_admission"
  end

  test "capability and connectivity must be fresh true facts from the declared revision" do
    candidates = [
      candidate("incapable", capability: "false"),
      candidate("unknown", connectivity: "unknown"),
      candidate("stale", observed_at: 899),
      candidate("future", observed_at: 1_011),
      candidate("old-revision", fact_revision: "facts-v0")
    ]

    policy =
      policy(%{
        ordinary_order: Enum.map(candidates, & &1.id),
        critical_order: Enum.map(candidates, & &1.id),
        maximum_fact_age_ms: 100,
        future_skew_ms: 10
      })

    assert {:ok, result} = TransportPolicy.select(candidates, request(), policy, 1_000)
    assert result["status"] == "deferred"
    assert entry(result, "incapable")["reason"] == "capability:false"
    assert entry(result, "unknown")["reason"] == "connectivity:unknown"
    assert entry(result, "stale")["reason"] == "capability:unknown"
    assert entry(result, "future")["reason"] == "capability:unknown"
    assert entry(result, "old-revision")["reason"] == "capability_revision"
  end

  test "policy and current request budgets both constrain eligibility" do
    cheap = candidate("cheap", cost: 10, power: 10, acknowledgements: [:network])
    costly = candidate("costly", cost: 60, power: 10, acknowledgements: [:network])
    hungry = candidate("hungry", cost: 10, power: 60, acknowledgements: [:network])
    unconfirmed = candidate("unconfirmed", cost: 0, power: 0, acknowledgements: [])
    candidates = [costly, hungry, unconfirmed, cheap]
    ids = ~w(costly hungry unconfirmed cheap)

    policy =
      policy(%{
        ordinary_order: ids,
        critical_order: ids,
        ordinary_max_cost_class: 50,
        ordinary_max_power_class: 50
      })

    assert {:ok, result} =
             TransportPolicy.select(
               candidates,
               request(%{maximum_cost_class: 40, maximum_power_class: 40}),
               policy,
               1_000
             )

    assert result["selected"]["candidate_id"] == "cheap"
    assert entry(result, "costly")["reason"] == "cost_budget"
    assert entry(result, "hungry")["reason"] == "power_budget"
    assert entry(result, "unconfirmed")["reason"] == "acknowledgement_unsupported"
  end

  test "acknowledgement layer and state govern completion, holding and fallback" do
    lorawan = candidate("lorawan")
    cellular = candidate("cellular", acknowledgements: [:durable_admission])
    policy = policy()
    critical = request(%{severity: :critical, maximum_cost_class: 100, maximum_power_class: 100})

    for {status, expected_status, expected_action} <- [
          {:pending, "pending", "wait"},
          {:unknown, "unknown", "hold"}
        ] do
      request = %{critical | acknowledgement: acknowledgement(status, :durable_admission)}
      assert {:ok, result} = TransportPolicy.select([lorawan, cellular], request, policy, 1_000)
      assert result["status"] == expected_status
      assert result["action"] == expected_action
      assert result["selected"] == nil
    end

    insufficient = %{critical | acknowledgement: acknowledgement(:acknowledged, :network)}

    assert {:ok, result} =
             TransportPolicy.select([lorawan, cellular], insufficient, policy, 1_000)

    assert result["status"] == "unknown"
    assert result["reason"] == "acknowledgement_layer_insufficient"
    assert result["action"] == "hold"

    acknowledged =
      %{critical | acknowledgement: acknowledgement(:acknowledged, :durable_admission)}

    assert {:ok, result} =
             TransportPolicy.select([lorawan, cellular], acknowledged, policy, 1_000)

    assert result["status"] == "acknowledged"
    assert result["action"] == "none"

    failed = %{critical | acknowledgement: acknowledgement(:failed, :network)}
    assert {:ok, result} = TransportPolicy.select([lorawan, cellular], failed, policy, 1_000)
    assert result["status"] == "selected"
    assert result["reason"] == "fallback_after_failed_acknowledgement"
    assert result["selected"]["candidate_id"] == "cellular"
    assert entry(result, "lorawan")["reason"] == "acknowledgement_failed"
  end

  test "candidate and policy identities reject mutation and malformed scopes" do
    original = candidate("lorawan")
    assert {:ok, ^original} = TransportCandidate.validate(original)

    for change <- [
          %{bearer: "wifi"},
          %{application_protocol: "mqtt"},
          %{cost_class: 20},
          %{power_class: 20},
          %{acknowledgement_layers: [:radio]}
        ] do
      assert {:error, %{code: :conflict}} =
               TransportCandidate.validate(struct(original, change))
    end

    wrong_kind =
      candidate_input("wrong-kind",
        capability_fact: fact("wrong-kind-cap", "transport.wrong-kind.capable", "true", :identity)
      )

    assert {:error, %{code: :conflict}} = TransportCandidate.new(wrong_kind)
    assert {:error, _} = TransportCandidate.new(Map.put(candidate_input("extra"), :extra, true))
    assert {:error, _} = TransportCandidate.validate(:invalid)

    original_policy = policy()

    for change <- [
          %{revision: "policy-v2"},
          %{fact_policy_revision: "facts-v2"},
          %{ordinary_order: ~w(cellular lorawan)},
          %{critical_max_cost_class: 99},
          %{critical_acknowledgement: :application},
          %{ordinary_no_route: :unavailable}
        ] do
      assert {:error, %{code: :conflict}} =
               TransportPolicy.validate(struct(original_policy, change))
    end

    assert {:error, _} = TransportPolicy.new(Map.put(policy_input(), :extra, true))
    assert {:error, _} = TransportPolicy.new(%{policy_input() | ordinary_order: []})
    assert {:error, _} = TransportPolicy.validate(:invalid)
    assert {:error, _} = TransportPolicy.select([], request(), original_policy, 1_000.0)
    assert {:error, _} = TransportPolicy.select(:improper, request(), original_policy, 1_000)

    no_ack_policy = policy(%{ordinary_acknowledgement: :none})
    with_ack = request(%{acknowledgement: acknowledgement(:failed, :network)})

    assert {:error, %{code: :conflict}} =
             TransportPolicy.select([original], with_ack, no_ack_policy, 1_000)
  end

  test "candidate count and identities are bounded without silent truncation" do
    candidates = for number <- 1..64, do: candidate("route-#{number}")
    ids = Enum.map(candidates, & &1.id)
    policy = policy(%{ordinary_order: ids, critical_order: ids})

    assert {:ok, result} = TransportPolicy.select(candidates, request(), policy, 1_000)
    assert result["qualified_count"] == 64
    assert result["selected"]["candidate_id"] == "route-1"

    assert {:error, %{code: :limit_exceeded}} =
             TransportPolicy.select(
               candidates ++ [candidate("route-65")],
               request(),
               policy,
               1_000
             )

    duplicate = hd(candidates)

    assert {:error, %{code: :duplicate_id}} =
             TransportPolicy.select([duplicate, duplicate], request(), policy(), 1_000)
  end

  property "candidate input order cannot change a transport decision" do
    check all(available <- list_of(boolean(), length: 3)) do
      candidates =
        ~w(lorawan cellular wifi)
        |> Enum.zip(available)
        |> Enum.map(fn {id, available?} ->
          candidate(id, connectivity: if(available?, do: "true", else: "false"))
        end)

      policy =
        policy(%{
          ordinary_order: ~w(lorawan cellular wifi),
          critical_order: ~w(lorawan cellular wifi)
        })

      {:ok, forward} = TransportPolicy.select(candidates, request(), policy, 1_000)
      {:ok, reverse} = TransportPolicy.select(Enum.reverse(candidates), request(), policy, 1_000)
      assert forward == reverse
    end
  end

  defp entry(result, id), do: Enum.find(result["candidates"], &(&1["candidate_id"] == id))

  defp acknowledgement(status, layer),
    do: %{delivery_id: "delivery-1", candidate_id: "lorawan", layer: layer, status: status}

  defp request(changes \\ %{}),
    do:
      Map.merge(
        %{
          id: "request-1",
          severity: :ordinary,
          purpose: :telemetry,
          maximum_cost_class: 50,
          maximum_power_class: 50,
          acknowledgement: nil
        },
        changes
      )

  defp policy(changes \\ %{}) do
    {:ok, value} = TransportPolicy.new(Map.merge(policy_input(), changes))
    value
  end

  defp policy_input,
    do: %{
      id: "bike-transport",
      revision: "policy-v1",
      fact_policy_revision: "facts-v1",
      ordinary_order: ["lorawan"],
      critical_order: ["lorawan", "cellular"],
      maximum_fact_age_ms: 100,
      future_skew_ms: 10,
      ordinary_max_cost_class: 50,
      critical_max_cost_class: 100,
      ordinary_max_power_class: 50,
      critical_max_power_class: 100,
      ordinary_acknowledgement: :network,
      critical_acknowledgement: :durable_admission,
      ordinary_no_route: :store_and_retry,
      critical_no_route: :unavailable
    }

  defp candidate(id, options \\ []) do
    {:ok, value} = TransportCandidate.new(candidate_input(id, options))
    value
  end

  defp candidate_input(id, options \\ []) do
    observed_at = Keyword.get(options, :observed_at, 1_000)
    revision = Keyword.get(options, :fact_revision, "facts-v1")

    capability =
      Keyword.get_lazy(options, :capability_fact, fn ->
        fact(
          "#{id}-capability",
          TransportCandidate.capability_predicate(id),
          Keyword.get(options, :capability, "true"),
          :capability,
          observed_at,
          revision
        )
      end)

    connectivity =
      fact(
        "#{id}-connectivity",
        TransportCandidate.connectivity_predicate(id),
        Keyword.get(options, :connectivity, "true"),
        :transport,
        observed_at,
        revision
      )

    %{
      id: id,
      bearer: Keyword.get(options, :bearer, id),
      application_protocol: Keyword.get(options, :protocol, "fixture-protocol"),
      capability: capability,
      connectivity: connectivity,
      cost_class: Keyword.get(options, :cost, 10),
      power_class: Keyword.get(options, :power, 10),
      acknowledgement_layers:
        Keyword.get(options, :acknowledgements, [:network, :durable_admission])
    }
  end

  defp fact(id, predicate, status, kind, observed_at \\ 1_000, revision \\ "facts-v1") do
    observation =
      Fixtures.observation(%{
        id: "capture-#{id}",
        observed_at: observed_at,
        ingress: "imported"
      })

    {:ok, evidence} =
      Evidence.new(%{
        id: id,
        kind: kind,
        claim: %{
          "schema" => "wtr.policy-fact.v1",
          "predicate" => predicate,
          "status" => status,
          "policy_revision" => revision,
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
