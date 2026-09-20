defmodule Wotex.Tracker.Service.RuleStoreTest do
  @moduledoc false
  use ExUnit.Case, async: true
  import Wotex.Tracker.Service.Fixtures

  alias Exqlite.Sqlite3

  alias Wotex.Tracker.{
    Evidence,
    EvidenceBundle,
    PolicyFact,
    TransportCandidate,
    TransportDegradation,
    TransportPolicy
  }

  alias Wotex.Tracker.Service.{RuleEventProjection, RuleTransition, Store}

  test "state, deduplication and event intent commit at one generation and survive restart" do
    {store, directory} = store()
    %{baseline: baseline, degraded: degraded, degraded_result: result} = transitions()

    assert {:ok, first} = Store.commit_rule(store, baseline)
    assert first["generation"] == "1"
    assert first["event_disposition"] == "none"

    assert {:ok, second} = Store.commit_rule(store, degraded)
    assert second["generation"] == "2"
    assert second["event_disposition"] == "recorded"
    assert second["event_id"] == result["event"]["id"]

    assert {:ok, durable} =
             Store.rule_state(store, "workshop", "transport_degradation", "health")

    assert durable["generation"] == "2"
    assert durable["state_identity"] == result["state"].identity
    assert {:ok, restored} = TransportDegradation.state_from_map(durable["state"])
    assert restored === result["state"]

    assert {:ok, intent} = Store.rule_event(store, "workshop", result["event"]["id"])
    assert intent["generation"] == "2"
    assert intent["event"] == result["event"]
    assert intent["physical_action_dispatch"] == "separate_authorization_required"

    assert {:ok, %{"items" => [%{"event" => envelope}]}} =
             Store.events(store, replay(%{now: now() + 1}))

    assert envelope == %{
             "type" => "tracker.event",
             "data" => RuleEventProjection.public(result["event"])
           }

    assert {:ok, %{"items" => [%{"id" => "transport_degradation:health"}]}} =
             Store.snapshot(store, query(%{kind: "rules"}))

    GenServer.stop(store.pid)
    {reopened, _} = store(directory: directory)

    assert {:ok, %{"state_identity" => identity}} =
             Store.rule_state(reopened, "workshop", "transport_degradation", "health")

    assert identity == result["state"].identity
  end

  test "exact retries are idempotent and stale expected state loses without a partial event" do
    {store, _} = store()

    %{baseline: baseline, degraded: degraded, baseline_state: baseline_state, policy: policy} =
      transitions()

    assert {:ok, accepted} = Store.commit_rule(store, baseline)
    assert {:ok, duplicate} = Store.commit_rule(store, baseline)
    assert duplicate["disposition"] == "duplicate"
    assert duplicate["generation"] == accepted["generation"]
    assert {:ok, _} = Store.commit_rule(store, degraded)

    {:ok, unavailable} =
      TransportPolicy.select([], request("stale"), policy.transport_policy, now() + 2)

    {:ok, stale_result} =
      TransportDegradation.evaluate(
        baseline_state,
        unavailable,
        policy,
        :live,
        now() + 2
      )

    {:ok, stale} = RuleTransition.new("workshop", baseline_state, stale_result)
    assert {:error, :rule_conflict} = Store.commit_rule(store, stale)

    assert {:error, :not_found} =
             Store.rule_event(store, "workshop", stale_result["event"]["id"])

    assert {:ok, %{"generation" => "2"}} =
             Store.rule_state(store, "workshop", "transport_degradation", "health")
  end

  test "independent writers serialize the same transition without repeating its event" do
    {first, directory} = store()
    {second, _} = store(directory: directory)
    transition = transitions().baseline

    results =
      [first, second]
      |> Enum.map(&Task.async(fn -> Store.commit_rule(&1, transition) end))
      |> Task.await_many()

    assert Enum.sort(Enum.map(results, fn {:ok, result} -> result["disposition"] end)) ==
             ["accepted", "duplicate"]

    assert {:ok, %{"generation" => "1"}} =
             Store.rule_state(first, "workshop", "transport_degradation", "health")

    assert {:ok, %{"items" => []}} = Store.events(first, replay())
  end

  test "pre-commit failure rolls back and a lost acknowledgement is resolved by state identity" do
    transition = transitions().baseline

    {before_commit, _} =
      store(fault: fn phase -> if phase == :rule_before_commit, do: :abort, else: :ok end)

    assert {:error, :injected_failure} = Store.commit_rule(before_commit, transition)

    assert {:error, :not_found} =
             Store.rule_state(before_commit, "workshop", "transport_degradation", "health")

    {after_commit, directory} =
      store(fault: fn phase -> if phase == :rule_after_commit, do: :abort, else: :ok end)

    assert {:error, :unknown} = Store.commit_rule(after_commit, transition)

    assert {:ok, %{"state_identity" => identity}} =
             Store.rule_state(after_commit, "workshop", "transport_degradation", "health")

    assert identity == transition.state_identity
    GenServer.stop(after_commit.pid)
    {reopened, _} = store(directory: directory)
    assert {:ok, %{"disposition" => "duplicate"}} = Store.commit_rule(reopened, transition)
  end

  test "schema two upgrades transactionally and retains existing state and queue support" do
    directory = directory()
    path = Path.join(directory, "tracker.db")
    {:ok, db} = Sqlite3.open(path)
    schema = File.read!(Application.app_dir(:wotex_tracker_service, "priv/schema/2.sql"))
    :ok = Sqlite3.execute(db, schema)
    :ok = Sqlite3.execute(db, "INSERT INTO scopes VALUES('existing',3)")
    :ok = Sqlite3.close(db)
    :ok = File.chmod(path, 0o600)

    {store, _} = store(directory: directory)
    assert {:ok, %{"schema" => "9"}} = Store.readiness(store)
    assert {:ok, %{"generation" => "3"}} = Store.snapshot(store, query(%{scope: "existing"}))
    assert {:ok, %{"generation" => "1"}} = Store.commit_rule(store, transitions().baseline)
  end

  test "schema three moves only rule history out of public asset state" do
    directory = directory()
    path = Path.join(directory, "tracker.db")
    {:ok, db} = Sqlite3.open(path)
    schema = File.read!(Application.app_dir(:wotex_tracker_service, "priv/schema/3.sql"))
    :ok = Sqlite3.execute(db, schema)

    :ok =
      Sqlite3.execute(db, """
      INSERT INTO scopes VALUES('existing',3),('other',1);
      INSERT INTO rule_states VALUES('existing','heartbeat','silence','state-2','{}',2,1,'transition-2');
      INSERT INTO records VALUES('existing','state','heartbeat:silence',1,'{"rule":1}');
      INSERT INTO records VALUES('existing','state','heartbeat:silence',2,'{"rule":2}');
      INSERT INTO records VALUES('existing','state','urn:uuid:asset',3,'{"public":{}}');
      INSERT INTO records VALUES('other','state','heartbeat:silence',1,'{"public":{}}');
      """)

    :ok = Sqlite3.close(db)
    :ok = File.chmod(path, 0o600)

    {store, _} = store(directory: directory)
    assert {:ok, %{"schema" => "9"}} = Store.readiness(store)

    assert {:ok, %{"items" => [%{"id" => "urn:uuid:asset"}]}} =
             Store.snapshot(store, query(%{scope: "existing"}))

    assert {:ok, %{"items" => [%{"id" => "heartbeat:silence", "generation" => "2"}]}} =
             Store.snapshot(store, query(%{scope: "existing", kind: "rules"}))

    assert {:ok, %{"items" => [%{"value" => %{"rule" => 1}}, %{"value" => %{"rule" => 2}}]}} =
             Store.history(store, %{
               scope: "existing",
               kind: "rules",
               id: "heartbeat:silence",
               generation: nil,
               after: "0",
               limit: 10
             })

    assert {:ok, %{"items" => [%{"id" => "heartbeat:silence"}]}} =
             Store.snapshot(store, query(%{scope: "other"}))
  end

  test "transition admission rejects stable results, mutation and invalid queries" do
    %{baseline: baseline, baseline_state: state, healthy_decision: decision, policy: policy} =
      transitions()

    assert {:ok, ^baseline} = RuleTransition.validate(baseline)

    assert {:error, :invalid_rule_transition} =
             RuleTransition.validate(%{baseline | state_identity: "changed"})

    {:ok, stable} =
      TransportDegradation.evaluate(state, decision, policy, :live, now())

    assert stable["state_changed"] == false
    assert {:error, :invalid_rule_transition} = RuleTransition.new("workshop", state, stable)

    {store, _} = store()
    assert {:error, :invalid_rule_transition} = Store.commit_rule(store, :invalid)
    assert {:error, :invalid_query} = Store.rule_state(store, "", "kind", "rule")
    assert {:error, :invalid_query} = Store.rule_event(store, "workshop", "")
  end

  test "replay event intent is retained as prohibited" do
    {store, _} = store()
    %{baseline_result: first, unavailable_decision: unavailable, policy: policy} = transitions()
    {:ok, baseline} = RuleTransition.new("workshop", nil, first)
    assert {:ok, _} = Store.commit_rule(store, baseline)

    {:ok, replay_result} =
      TransportDegradation.evaluate(first["state"], unavailable, policy, :replay, now() + 1)

    {:ok, replay_transition} =
      RuleTransition.new("workshop", first["state"], replay_result)

    assert {:ok, %{"event_disposition" => "recorded"}} =
             Store.commit_rule(store, replay_transition)

    assert {:ok, intent} = Store.rule_event(store, "workshop", replay_result["event"]["id"])
    assert intent["mode"] == "replay"
    assert intent["physical_action_dispatch"] == "prohibited"
  end

  defp transitions do
    transport_policy = transport_policy()
    policy = degradation_policy(transport_policy)
    candidates = [candidate("lorawan")]

    {:ok, healthy} =
      TransportPolicy.select(candidates, request("healthy"), transport_policy, now())

    {:ok, baseline_result} = TransportDegradation.evaluate(nil, healthy, policy, :live, now())
    baseline_state = baseline_result["state"]

    {:ok, unavailable} =
      TransportPolicy.select([], request("unavailable"), transport_policy, now() + 1)

    {:ok, degraded_result} =
      TransportDegradation.evaluate(
        baseline_state,
        unavailable,
        policy,
        :live,
        now() + 1
      )

    {:ok, baseline} = RuleTransition.new("workshop", nil, baseline_result)
    {:ok, degraded} = RuleTransition.new("workshop", baseline_state, degraded_result)

    %{
      baseline: baseline,
      degraded: degraded,
      baseline_result: baseline_result,
      degraded_result: degraded_result,
      baseline_state: baseline_state,
      healthy_decision: healthy,
      unavailable_decision: unavailable,
      policy: policy
    }
  end

  defp transport_policy do
    {:ok, value} =
      TransportPolicy.new(%{
        id: "transport",
        revision: "transport-v1",
        fact_policy_revision: "facts-v1",
        ordinary_order: ["lorawan"],
        critical_order: ["lorawan"],
        maximum_fact_age_ms: 1_000,
        future_skew_ms: 0,
        ordinary_max_cost_class: 100,
        critical_max_cost_class: 100,
        ordinary_max_power_class: 100,
        critical_max_power_class: 100,
        ordinary_acknowledgement: :none,
        critical_acknowledgement: :none,
        ordinary_no_route: :store_and_retry,
        critical_no_route: :unavailable
      })

    value
  end

  defp degradation_policy(transport_policy) do
    {:ok, value} =
      TransportDegradation.new(%{
        id: "health",
        revision: "health-v1",
        transport_policy: transport_policy,
        healthy_candidate_ids: ["lorawan"],
        maximum_decision_age_ms: 1_000,
        future_skew_ms: 0
      })

    value
  end

  defp candidate(id) do
    {:ok, value} =
      TransportCandidate.new(%{
        id: id,
        bearer: "lorawan-eu868",
        application_protocol: "fixture-protocol",
        capability: fact("capability", TransportCandidate.capability_predicate(id), :capability),
        connectivity:
          fact("connectivity", TransportCandidate.connectivity_predicate(id), :transport),
        cost_class: 10,
        power_class: 10,
        acknowledgement_layers: []
      })

    value
  end

  defp fact(id, predicate, kind) do
    observation = observation(%{id: "capture-#{id}", observed_at: now()})

    {:ok, evidence} =
      Evidence.new(%{
        id: id,
        kind: kind,
        claim: %{
          "schema" => "wtr.policy-fact.v1",
          "predicate" => predicate,
          "status" => "true",
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

  defp request(id),
    do: %{
      id: id,
      severity: :critical,
      purpose: :event,
      maximum_cost_class: 100,
      maximum_power_class: 100,
      acknowledgement: nil
    }

  defp now, do: 1_700_000_000_000
end
