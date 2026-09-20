defmodule Wotex.Tracker.Service.RuleSchedulerTest do
  use ExUnit.Case, async: true

  import Wotex.Tracker.Service.Fixtures

  alias Exqlite.Sqlite3

  alias Wotex.Tracker.{
    BatteryTransition,
    Evidence,
    EvidenceBundle,
    HeartbeatTransition,
    Measurement,
    MeasurementSample,
    PolicyFact,
    TransportCandidate,
    TransportDegradation,
    TransportPolicy
  }

  alias Wotex.Tracker.Service.{RuleScheduler, RuleTransition, SQL, Store}

  test "a monotonic deadline commits one live overdue heartbeat intent" do
    {store, _} = store()
    now = 1_700_000_000_000
    policy = heartbeat_policy("heartbeat", 80)
    heartbeat = observation(%{id: "heartbeat", observed_at: now})
    {:ok, baseline_result} = HeartbeatTransition.evaluate(nil, heartbeat, policy, :live, now)
    {:ok, baseline} = RuleTransition.new("workshop", nil, baseline_result)
    assert {:ok, %{"generation" => "1"}} = Store.commit_rule(store, baseline)

    due_at = baseline_result["state"].due_at

    {:ok, expected} =
      HeartbeatTransition.evaluate(
        baseline_result["state"],
        nil,
        policy,
        :live,
        due_at
      )

    {clock, wall} = advancing_clock(now)

    scheduler =
      start_supervised!({RuleScheduler, store: store, clock: clock, refresh_interval: 1_000})

    assert :ok = RuleScheduler.refresh(scheduler)

    assert {:ok, %{"scheduled" => 1, "jobs" => [%{"due_at" => ^due_at}]}} =
             RuleScheduler.snapshot(scheduler)

    :atomics.put(wall, 1, now - 1_000_000)

    eventually(fn ->
      match?(
        {:ok, %{"generation" => "2", "state" => %{"status" => "overdue"}}},
        Store.rule_state(store, "workshop", "heartbeat", policy.id)
      )
    end)

    event_id = expected["event"]["id"]

    assert {:ok,
            %{
              "mode" => "live",
              "physical_action_dispatch" => "separate_authorization_required",
              "event" => %{"id" => ^event_id, "kind" => "heartbeat.overdue"}
            }} = Store.rule_event(store, "workshop", event_id)

    eventually(fn -> match?({:ok, %{"scheduled" => 0}}, RuleScheduler.snapshot(scheduler)) end)
  end

  test "battery freshness expiry is persisted without inventing an alert" do
    {store, _} = store()
    now = 1_700_000_000_000
    policy = battery_policy("battery", 60)

    {:ok, baseline_result} =
      BatteryTransition.evaluate(nil, sample("normal", 3.0, now), policy, :live, now)

    {:ok, baseline} = RuleTransition.new("workshop", nil, baseline_result)
    assert {:ok, %{"generation" => "1"}} = Store.commit_rule(store, baseline)
    {clock, _wall} = advancing_clock(now)

    scheduler =
      start_supervised!({RuleScheduler, store: store, clock: clock, refresh_interval: 1_000})

    assert :ok = RuleScheduler.refresh(scheduler)

    eventually(fn ->
      match?(
        {:ok, %{"generation" => "2", "state" => %{"status" => "unknown"}}},
        Store.rule_state(store, "workshop", "battery", policy.id)
      )
    end)

    assert {:ok, %{"scheduled" => 0}} =
             eventually_value(fn -> RuleScheduler.snapshot(scheduler) end)
  end

  test "a future battery sample is reconsidered at its permitted skew boundary" do
    {store, _} = store()
    now = 1_700_000_000_000
    policy = battery_policy("future-battery", 1_000, 20)
    future = sample("future-low", 2.0, now + 80)
    {:ok, baseline_result} = BatteryTransition.evaluate(nil, future, policy, :live, now)
    assert baseline_result["battery_status"] == "unknown"
    {:ok, baseline} = RuleTransition.new("workshop", nil, baseline_result)
    assert {:ok, %{"generation" => "1"}} = Store.commit_rule(store, baseline)
    {clock, _wall} = advancing_clock(now)

    _scheduler =
      start_supervised!({RuleScheduler, store: store, clock: clock, refresh_interval: 1_000})

    eventually(fn ->
      match?(
        {:ok, %{"generation" => "2", "state" => %{"status" => "low"}}},
        Store.rule_state(store, "workshop", "battery", policy.id)
      )
    end)
  end

  test "restart expires persisted transport health at the first stale millisecond" do
    {store, directory} = store()
    now = 1_700_000_000_000
    {policy, decision} = transport_rule(now, 50, 0)
    {:ok, baseline_result} = TransportDegradation.evaluate(nil, decision, policy, :live, now)
    assert baseline_result["transport_status"] == "healthy"
    {:ok, baseline} = RuleTransition.new("workshop", nil, baseline_result)
    assert {:ok, %{"generation" => "1"}} = Store.commit_rule(store, baseline)
    GenServer.stop(store.pid)
    {reopened, _} = store(directory: directory)

    scheduler =
      start_supervised!(
        {RuleScheduler, store: reopened, clock: fn -> now + 100 end, refresh_interval: 1_000}
      )

    assert :ok = RuleScheduler.refresh(scheduler)

    eventually(fn ->
      match?(
        {:ok,
         %{
           "generation" => "2",
           "state" => %{"status" => "unknown", "evaluated_at" => evaluated_at}
         }}
        when evaluated_at == now + 51,
        Store.rule_state(reopened, "workshop", "transport_degradation", policy.id)
      )
    end)

    assert {:ok, %{"scheduled" => 0}} =
             eventually_value(fn -> RuleScheduler.snapshot(scheduler) end)

    assert {:ok, %{"items" => []}} = Store.events(reopened, replay(%{now: now + 100}))
  end

  test "a future transport decision is reconsidered at its permitted skew boundary" do
    {store, _} = store()
    now = 1_700_000_000_000
    {policy, decision} = transport_rule(now + 80, 1_000, 20)
    {:ok, baseline_result} = TransportDegradation.evaluate(nil, decision, policy, :live, now)
    assert baseline_result["transport_status"] == "unknown"
    {:ok, baseline} = RuleTransition.new("workshop", nil, baseline_result)
    assert {:ok, %{"generation" => "1"}} = Store.commit_rule(store, baseline)
    wall = :atomics.new(1, [])
    monotonic = :atomics.new(1, [])
    :atomics.put(wall, 1, now)

    scheduler =
      start_supervised!(
        {RuleScheduler,
         store: store,
         clock: fn -> :atomics.get(wall, 1) end,
         monotonic_clock: fn -> :atomics.get(monotonic, 1) end,
         refresh_interval: 1_000}
      )

    assert :ok = RuleScheduler.refresh(scheduler)
    [job] = scheduler |> :sys.get_state() |> Map.fetch!(:jobs) |> Map.values()
    assert job.due_at == now + 60
    :atomics.put(wall, 1, now + 60)
    :atomics.put(monotonic, 1, 60)
    send(scheduler, {:deadline, job.key, job.token})

    eventually(fn ->
      match?(
        {:ok, %{"generation" => "2", "state" => %{"status" => "healthy"}}},
        Store.rule_state(store, "workshop", "transport_degradation", policy.id)
      )
    end)

    assert {:ok, %{"jobs" => [%{"kind" => "transport_degradation", "due_at" => due_at}]}} =
             RuleScheduler.snapshot(scheduler)

    assert due_at == now + 1_081
  end

  test "restart rebuilds an elapsed deadline and store loss stops its scheduler" do
    {store, directory} = store()
    now = 1_700_000_000_000
    commit_heartbeat(store, "restarted", now, 10)
    GenServer.stop(store.pid)
    {reopened, _} = store(directory: directory)

    {:ok, scheduler} =
      GenServer.start(RuleScheduler,
        store: reopened,
        clock: fn -> now + 100 end,
        refresh_interval: 1_000
      )

    on_exit(fn -> if Process.alive?(scheduler), do: GenServer.stop(scheduler) end)
    assert :ok = RuleScheduler.refresh(scheduler)

    eventually(fn ->
      match?(
        {:ok, %{"generation" => "2", "state" => %{"status" => "overdue"}}},
        Store.rule_state(reopened, "workshop", "heartbeat", "restarted")
      )
    end)

    monitor = Process.monitor(scheduler)
    GenServer.stop(reopened.pid)
    assert_receive {:DOWN, ^monitor, :process, ^scheduler, :normal}, 1_000
    assert {:error, :storage_unavailable} = RuleScheduler.snapshot(scheduler)
  end

  test "refresh admits new durable jobs, ignores stale timer messages and enforces capacity" do
    {store, _} = store()
    now = 1_700_000_000_000
    {clock, _wall} = advancing_clock(now)
    monotonic = :atomics.new(1, [])

    scheduler =
      start_supervised!(
        {RuleScheduler,
         store: store,
         clock: clock,
         monotonic_clock: fn -> :atomics.get(monotonic, 1) end,
         refresh_interval: 1_000,
         max_rules: 1}
      )

    assert :ok = RuleScheduler.refresh(scheduler)
    assert {:ok, %{"scheduled" => 0}} = RuleScheduler.snapshot(scheduler)
    send(scheduler, {:deadline, {"foreign", "heartbeat", "rule"}, make_ref()})
    assert Process.alive?(scheduler)

    commit_heartbeat(store, "first", now, 10_000)
    assert :ok = RuleScheduler.refresh(scheduler)
    assert {:ok, %{"scheduled" => 1}} = RuleScheduler.snapshot(scheduler)

    scheduler_state = :sys.get_state(scheduler)
    [job] = Map.values(scheduler_state.jobs)
    send(scheduler, {:deadline, job.key, job.token})
    send(scheduler, :unknown_message)
    Process.sleep(5)
    assert {:ok, %{"scheduled" => 1}} = RuleScheduler.snapshot(scheduler)

    {:ok, durable} = Store.rule_state(store, "workshop", "heartbeat", "first")
    {:ok, previous} = HeartbeatTransition.state_from_map(durable["state"])
    policy = heartbeat_policy("first", 10_000)
    newer = observation(%{id: "first-newer", observed_at: now + 1_000})
    {:ok, result} = HeartbeatTransition.evaluate(previous, newer, policy, :live, now + 1_000)
    {:ok, transition} = RuleTransition.new("workshop", previous, result)
    assert {:ok, _} = Store.commit_rule(store, transition)
    :atomics.put(monotonic, 1, 20_000)
    send(scheduler, {:deadline, job.key, job.token})

    assert {:ok, %{"jobs" => [%{"due_at" => due_at}]}} =
             eventually_matching(fn -> RuleScheduler.snapshot(scheduler) end, fn
               {:ok, %{"jobs" => [%{"due_at" => value}]}} -> value == now + 11_001
               _ -> false
             end)

    assert due_at == now + 11_001

    commit_heartbeat(store, "second", now, 10_000)
    assert {:error, :capacity_exceeded} = RuleScheduler.refresh(scheduler)
    assert {:error, :capacity_exceeded} = Store.scheduled_rules(store, 1)
    assert {:ok, [_, _]} = Store.scheduled_rules(store, 2)
    assert {:error, :invalid_query} = Store.scheduled_rules(store, 0)
  end

  test "invalid scheduler options start nothing" do
    {store, _} = store()
    assert {:ok, scheduler} = GenServer.start(RuleScheduler, store: store)
    assert :ok = GenServer.stop(scheduler)
    assert RuleScheduler.format_status(%{state: :private})[:state] == :redacted
    assert {:error, :invalid_options} = GenServer.start(RuleScheduler, store: store, max_rules: 0)

    assert {:error, :invalid_options} =
             GenServer.start(RuleScheduler, store: store, unknown: true)

    assert {:error, :invalid_options} = GenServer.start(RuleScheduler, [])
    assert {:error, :invalid_options} = GenServer.start(RuleScheduler, store: :invalid)

    assert {:ok, empty_supervisor} = Supervisor.start_link([], strategy: :one_for_one)

    assert {:ok, unresolved} =
             GenServer.start(RuleScheduler,
               store: {:supervisor, empty_supervisor},
               refresh_interval: 1_000
             )

    assert {:error, :storage_unavailable} = RuleScheduler.refresh(unresolved)
    GenServer.stop(unresolved)
  end

  test "default host clocks execute an elapsed persisted deadline" do
    {store, _} = store()
    now = System.system_time(:millisecond) - 100
    commit_heartbeat(store, "default-clock", now, 0)
    scheduler = start_supervised!({RuleScheduler, store: store, refresh_interval: 1_000})
    assert :ok = RuleScheduler.refresh(scheduler)

    eventually(fn ->
      match?(
        {:ok, %{"generation" => "2", "state" => %{"status" => "overdue"}}},
        Store.rule_state(store, "workshop", "heartbeat", "default-clock")
      )
    end)
  end

  test "an unresponsive supervisor cannot hold rule scheduling indefinitely" do
    unresponsive = spawn(fn -> Process.sleep(:infinity) end)

    assert {:ok, scheduler} =
             GenServer.start(RuleScheduler,
               store: {:supervisor, unresponsive},
               refresh_interval: 1_000
             )

    assert {:error, :storage_unavailable} = RuleScheduler.refresh(scheduler)
    assert :ok = GenServer.stop(scheduler)
    Process.exit(unresponsive, :kill)
  end

  test "refresh replaces a changed durable deadline and rejects its old timer token" do
    {store, _} = store()
    now = 1_700_000_000_000
    monotonic = :atomics.new(1, [])
    commit_heartbeat(store, "changed", now, 10_000)

    scheduler =
      start_supervised!(
        {RuleScheduler,
         store: store,
         clock: fn -> now end,
         monotonic_clock: fn -> :atomics.get(monotonic, 1) end,
         refresh_interval: 1_000}
      )

    assert :ok = RuleScheduler.refresh(scheduler)
    [old_job] = scheduler |> :sys.get_state() |> Map.fetch!(:jobs) |> Map.values()
    {:ok, durable} = Store.rule_state(store, "workshop", "heartbeat", "changed")
    {:ok, previous} = HeartbeatTransition.state_from_map(durable["state"])
    policy = heartbeat_policy("changed", 10_000)
    newer = observation(%{id: "changed-newer", observed_at: now + 1_000})
    {:ok, result} = HeartbeatTransition.evaluate(previous, newer, policy, :live, now + 1_000)
    {:ok, transition} = RuleTransition.new("workshop", previous, result)
    assert {:ok, _} = Store.commit_rule(store, transition)
    assert :ok = RuleScheduler.refresh(scheduler)
    [new_job] = scheduler |> :sys.get_state() |> Map.fetch!(:jobs) |> Map.values()
    assert new_job.due_at == now + 11_001
    refute new_job.token == old_job.token

    send(scheduler, {:deadline, old_job.key, old_job.token})
    assert {:ok, %{"jobs" => [%{"due_at" => due_at}]}} = RuleScheduler.snapshot(scheduler)
    assert due_at == now + 11_001
  end

  test "corrupt persisted rule documents fail closed during scheduling" do
    for kind <- ["heartbeat", "battery"] do
      {store, directory} = store()
      now = 1_700_000_000_000
      rule_id = "corrupt-#{kind}"

      case kind do
        "heartbeat" ->
          commit_heartbeat(store, rule_id, now, 10_000)

        "battery" ->
          policy = battery_policy(rule_id, 10_000)

          {:ok, result} =
            BatteryTransition.evaluate(nil, sample(rule_id, 3.0, now), policy, :live, now)

          {:ok, transition} = RuleTransition.new("workshop", nil, result)
          assert {:ok, _} = Store.commit_rule(store, transition)
      end

      {:ok, db} = Sqlite3.open(Path.join(directory, "tracker.db"), mode: :readwrite)

      SQL.rows!(
        db,
        "UPDATE rule_states SET document='{}' WHERE scope=? AND kind=? AND rule_id=?",
        [
          "workshop",
          kind,
          rule_id
        ]
      )

      assert :ok = Sqlite3.close(db)

      scheduler =
        start_supervised!({RuleScheduler, store: store, refresh_interval: 1_000}, id: make_ref())

      assert {:error, :storage_unavailable} = RuleScheduler.refresh(scheduler)
      assert {:ok, %{"scheduled" => 0}} = RuleScheduler.snapshot(scheduler)
    end
  end

  defp commit_heartbeat(store, id, now, silence) do
    policy = heartbeat_policy(id, silence)
    capture = observation(%{id: id, observed_at: now})
    {:ok, result} = HeartbeatTransition.evaluate(nil, capture, policy, :live, now)
    {:ok, transition} = RuleTransition.new("workshop", nil, result)
    assert {:ok, _} = Store.commit_rule(store, transition)
  end

  defp heartbeat_policy(id, silence) do
    {:ok, policy} =
      HeartbeatTransition.new(%{
        id: id,
        revision: "heartbeat-scheduler-v1",
        maximum_silence_ms: silence,
        future_skew_ms: 0
      })

    policy
  end

  defp battery_policy(id, age, skew \\ 0) do
    {:ok, policy} =
      BatteryTransition.new(%{
        id: id,
        revision: "battery-scheduler-v1",
        measurement_kind: "batteryVoltage",
        unit: "V",
        low_threshold: 2.5,
        clear_threshold: 2.8,
        maximum_age_ms: age,
        future_skew_ms: skew,
        accept_suspect: false
      })

    policy
  end

  defp transport_rule(evaluated_at, maximum_age, future_skew) do
    transport_policy = transport_policy()

    {:ok, policy} =
      TransportDegradation.new(%{
        id: "transport-health",
        revision: "transport-health-v1",
        transport_policy: transport_policy,
        healthy_candidate_ids: ["lorawan"],
        maximum_decision_age_ms: maximum_age,
        future_skew_ms: future_skew
      })

    {:ok, decision} =
      TransportPolicy.select(
        [transport_candidate(evaluated_at)],
        %{
          id: "transport-request",
          severity: :critical,
          purpose: :event,
          maximum_cost_class: 100,
          maximum_power_class: 100,
          acknowledgement: nil
        },
        transport_policy,
        evaluated_at
      )

    {policy, decision}
  end

  defp transport_policy do
    {:ok, policy} =
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

    policy
  end

  defp transport_candidate(observed_at) do
    {:ok, candidate} =
      TransportCandidate.new(%{
        id: "lorawan",
        bearer: "lorawan-eu868",
        application_protocol: "fixture-protocol",
        capability: transport_fact("capability", :capability, observed_at),
        connectivity: transport_fact("connectivity", :transport, observed_at),
        cost_class: 10,
        power_class: 10,
        acknowledgement_layers: []
      })

    candidate
  end

  defp transport_fact(id, kind, observed_at) do
    capture = observation(%{id: "transport-#{id}", observed_at: observed_at})

    predicate =
      if(kind == :capability,
        do: TransportCandidate.capability_predicate("lorawan"),
        else: TransportCandidate.connectivity_predicate("lorawan")
      )

    {:ok, evidence} =
      Evidence.new(%{
        id: "transport-#{id}",
        kind: kind,
        claim: %{
          "schema" => "wtr.policy-fact.v1",
          "predicate" => predicate,
          "status" => "true",
          "policy_revision" => "facts-v1",
          "reason" => "fixture"
        },
        source_observation_ids: [capture.id],
        evidence_ids: [],
        profile: {"transport", "1"},
        decoder: {"transport", "1"},
        confidence: :exact,
        reasons: ["fixture"],
        association_id: nil
      })

    {:ok, bundle} = EvidenceBundle.new([capture], [evidence])
    {:ok, fact} = PolicyFact.new("transport-#{id}", bundle)
    fact
  end

  defp sample(id, value, observed_at) do
    capture = observation(%{id: "capture-#{id}", observed_at: observed_at})

    {:ok, measurement} =
      Measurement.new(%{
        kind: "batteryVoltage",
        value: value,
        unit: "V",
        availability: :available,
        quality: :valid,
        raw: value,
        reason: "fixture"
      })

    {:ok, claim} = Measurement.to_map(measurement)

    {:ok, evidence} =
      Evidence.new(%{
        id: "battery-#{id}",
        kind: :measurement,
        claim: claim,
        source_observation_ids: [capture.id],
        evidence_ids: [],
        profile: {"battery", "1"},
        decoder: {"battery", "1"},
        confidence: :exact,
        reasons: ["fixture"],
        association_id: nil
      })

    {:ok, bundle} = EvidenceBundle.new([capture], [evidence])
    {:ok, sample} = MeasurementSample.new(evidence.id, bundle)
    sample
  end

  defp advancing_clock(now) do
    started = System.monotonic_time(:millisecond)
    wall = :atomics.new(1, [])
    :atomics.put(wall, 1, now)

    clock = fn ->
      :atomics.get(wall, 1) + System.monotonic_time(:millisecond) - started
    end

    {clock, wall}
  end

  defp eventually(check, attempts \\ 400)
  defp eventually(check, 0), do: assert(check.())

  defp eventually(check, attempts) do
    unless check.() do
      Process.sleep(5)
      eventually(check, attempts - 1)
    end
  end

  defp eventually_value(read, attempts \\ 400)
  defp eventually_value(read, 0), do: read.()

  defp eventually_value(read, attempts) do
    case read.() do
      {:ok, %{"scheduled" => 0}} = result ->
        result

      _ ->
        Process.sleep(5)
        eventually_value(read, attempts - 1)
    end
  end

  defp eventually_matching(read, accept, attempts \\ 400)
  defp eventually_matching(read, _accept, 0), do: read.()

  defp eventually_matching(read, accept, attempts) do
    result = read.()

    if accept.(result) do
      result
    else
      Process.sleep(5)
      eventually_matching(read, accept, attempts - 1)
    end
  end
end
