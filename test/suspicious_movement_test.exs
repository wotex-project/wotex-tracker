defmodule Wotex.Tracker.SuspiciousMovementTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Wotex.Tracker.{
    Evidence,
    EvidenceBundle,
    Fixtures,
    MotionTransition,
    PolicyFact,
    Position,
    PositionMovement,
    PositionOrder,
    PositionSample,
    SuspiciousMovement
  }

  test "confirmed movement plus armed and explicit owner absence triggers a stable event" do
    {motion, motion_policy} = motion_state("moving")
    armed = fact("armed", "asset.armed", "true", 2_000)
    absent = fact("absent", "owner.present", "false", 2_000)
    policy = policy(motion_policy)

    assert {:ok, live} =
             SuspiciousMovement.evaluate(
               motion,
               armed,
               absent,
               policy,
               :live,
               2_000
             )

    assert live["status"] == "triggered"
    assert live["truth"] == "true"

    assert live["conditions"] == %{
             "movement" => "true",
             "armed" => "true",
             "owner_absent" => "true"
           }

    assert live["event"]["kind"] == "suspicious_movement"
    assert live["event"]["active_trip_id"] == motion.active_trip.id
    assert live["event"]["armed_evidence_id"] == "armed"
    assert live["physical_action_dispatch"] == "separate_authorization_required"

    assert {:ok, replay} =
             SuspiciousMovement.evaluate(
               motion,
               armed,
               absent,
               policy,
               :replay,
               2_000
             )

    assert replay["event"] === live["event"]
    assert replay["physical_action_dispatch"] == "prohibited"
  end

  test "any explicit false condition clears the rule without an event" do
    {moving, motion_policy} = motion_state("moving")
    {stationary, _} = motion_state("stationary")
    armed = fact("armed", "asset.armed", "true", 2_000)
    disarmed = fact("disarmed", "asset.armed", "false", 2_000)
    absent = fact("absent", "owner.present", "false", 2_000)
    present = fact("present", "owner.present", "true", 2_000)
    policy = policy(motion_policy)

    for {motion, armed, owner} <- [
          {stationary, armed, absent},
          {moving, disarmed, absent},
          {moving, armed, present}
        ] do
      assert {:ok, result} =
               SuspiciousMovement.evaluate(motion, armed, owner, policy, :live, 2_000)

      assert result["status"] == "clear"
      assert result["truth"] == "false"
      assert result["event"] == nil
      assert result["physical_action_dispatch"] == "none"
    end
  end

  test "unknown owner presence stays unknown unless policy explicitly treats it as absence" do
    {motion, motion_policy} = motion_state("moving")
    armed = fact("armed", "asset.armed", "true", 2_000)
    unknown = fact("unknown-owner", "owner.present", "unknown", 2_000)

    assert {:ok, retained} =
             SuspiciousMovement.evaluate(
               motion,
               armed,
               unknown,
               policy(motion_policy),
               :live,
               2_000
             )

    assert retained["status"] == "unknown"
    assert retained["conditions"]["owner_absent"] == "unknown"
    assert retained["owner_unknown_interpretation"] == "unknown_retained"
    assert retained["event"] == nil

    explicit = policy(motion_policy, %{owner_unknown_as_absent: true})

    assert {:ok, triggered} =
             SuspiciousMovement.evaluate(
               motion,
               armed,
               unknown,
               explicit,
               :live,
               2_000
             )

    assert triggered["status"] == "triggered"
    assert triggered["owner_unknown_interpretation"] == "unknown_treated_as_absent"
    assert triggered["event"]["kind"] == "suspicious_movement"
  end

  test "stale, future and unknown armed facts remain unknown rather than absent" do
    {motion, motion_policy} = motion_state("moving")
    absent = fact("absent", "owner.present", "false", 2_000)
    policy = policy(motion_policy, %{maximum_fact_age_ms: 10, future_skew_ms: 5})

    for armed <- [
          fact("unknown", "asset.armed", "unknown", 2_000),
          fact("stale", "asset.armed", "true", 1_989),
          fact("future", "asset.armed", "true", 2_006)
        ] do
      assert {:ok, result} =
               SuspiciousMovement.evaluate(
                 motion,
                 armed,
                 absent,
                 policy,
                 :live,
                 2_000
               )

      assert result["status"] == "unknown"
      assert result["conditions"]["armed"] == "unknown"
      assert result["event"] == nil
    end
  end

  test "policy facts validate closed claims and choose the latest source observation" do
    first = observation("first", 1_000)
    latest = observation("latest", 1_001)
    evidence = fact_evidence("fact", "asset.armed", "true", [first.id, latest.id])
    {:ok, bundle} = EvidenceBundle.new([latest, first], [evidence])
    {:ok, fact} = PolicyFact.new(evidence.id, bundle)
    assert fact.observed_at == 1_001
    assert fact.observation_id == "latest"
    assert {:ok, ^fact} = PolicyFact.validate(fact)

    for change <- [
          %{"status" => "maybe"},
          %{"schema" => "other"},
          %{"extra" => true}
        ] do
      changed = %{evidence | claim: Map.merge(evidence.claim, change)}
      {:ok, changed_bundle} = EvidenceBundle.new([first, latest], [changed])
      assert {:error, _} = PolicyFact.new(changed.id, changed_bundle)
    end

    candidate = %{evidence | confidence: :candidate}
    {:ok, candidate_bundle} = EvidenceBundle.new([first, latest], [candidate])
    assert {:error, _} = PolicyFact.new(candidate.id, candidate_bundle)
    assert {:error, _} = PolicyFact.new("missing", bundle)
    assert {:error, _} = PolicyFact.validate(:invalid)
  end

  test "policy binds motion and fact scopes and rejects mismatched inputs" do
    {motion, motion_policy} = motion_state("moving")
    original = policy(motion_policy)

    for change <- [
          %{id: "other"},
          %{revision: "other"},
          %{motion_policy: motion_policy(%{revision: "other"})},
          %{armed_predicate: "asset.enabled"},
          %{owner_presence_predicate: "operator.present"},
          %{maximum_fact_age_ms: 2_000},
          %{future_skew_ms: 1},
          %{owner_unknown_as_absent: true}
        ] do
      changed = policy(motion_policy, change)
      refute changed.identity == original.identity
      assert {:error, %{code: :conflict}} = SuspiciousMovement.validate(struct(original, change))
    end

    for change <- [
          %{id: ""},
          %{motion_policy: :invalid},
          %{maximum_fact_age_ms: -1},
          %{future_skew_ms: 604_800_001},
          %{owner_unknown_as_absent: :yes},
          %{extra: true}
        ] do
      assert {:error, _} = SuspiciousMovement.new(Map.merge(policy_input(motion_policy), change))
    end

    armed = fact("armed", "wrong", "true", 2_000)
    absent = fact("absent", "owner.present", "false", 2_000)

    assert {:error, %{code: :conflict}} =
             SuspiciousMovement.evaluate(
               motion,
               armed,
               absent,
               original,
               :live,
               2_000
             )

    assert {:error, _} = SuspiciousMovement.validate(:invalid)
    assert {:error, _} = SuspiciousMovement.new(nil)

    assert {:error, _} =
             SuspiciousMovement.evaluate(motion, armed, absent, original, :bad, 2_000)
  end

  property "fact freshness equality is eligible and the next millisecond is unknown" do
    check all(maximum_age <- integer(0..10_000)) do
      {motion, motion_policy} = motion_state("moving")
      armed = fact("armed-#{maximum_age}", "asset.armed", "true", 2_000)
      absent = fact("absent-#{maximum_age}", "owner.present", "false", 2_000)
      policy = policy(motion_policy, %{maximum_fact_age_ms: maximum_age})

      {:ok, eligible} =
        SuspiciousMovement.evaluate(
          motion,
          armed,
          absent,
          policy,
          :replay,
          2_000 + maximum_age
        )

      assert eligible["status"] == "triggered"

      {:ok, stale} =
        SuspiciousMovement.evaluate(
          motion,
          armed,
          absent,
          policy,
          :replay,
          2_001 + maximum_age
        )

      assert stale["status"] == "unknown"
    end
  end

  defp policy(motion_policy, changes \\ %{}) do
    {:ok, value} = SuspiciousMovement.new(Map.merge(policy_input(motion_policy), changes))
    value
  end

  defp policy_input(motion_policy),
    do: %{
      id: "suspicious-rule",
      revision: "suspicious-v1",
      motion_policy: motion_policy,
      armed_predicate: "asset.armed",
      owner_presence_predicate: "owner.present",
      maximum_fact_age_ms: 1_000,
      future_skew_ms: 0,
      owner_unknown_as_absent: false
    }

  defp fact(id, predicate, status, observed_at) do
    observation = observation("capture-#{id}", observed_at)
    evidence = fact_evidence(id, predicate, status, [observation.id])
    {:ok, bundle} = EvidenceBundle.new([observation], [evidence])
    {:ok, fact} = PolicyFact.new(id, bundle)
    fact
  end

  defp fact_evidence(id, predicate, status, source_ids) do
    {:ok, evidence} =
      Evidence.new(%{
        id: id,
        kind: if(predicate == "owner.present", do: :transport, else: :identity),
        claim: %{
          "schema" => "wtr.policy-fact.v1",
          "predicate" => predicate,
          "status" => status,
          "policy_revision" => "fixture-v1",
          "reason" => "fixture"
        },
        source_observation_ids: source_ids,
        evidence_ids: [],
        profile: {"policy", "1"},
        decoder: {"policy", "1"},
        confidence: :exact,
        reasons: ["fixture"],
        association_id: nil
      })

    evidence
  end

  defp motion_state(status) do
    policy = motion_policy()
    first = position("#{status}-first", 0, 0, 0)
    {:ok, baseline} = MotionTransition.evaluate(nil, first, policy, :replay, 0)

    case status do
      "unknown" ->
        {baseline["state"], policy}

      "moving" ->
        second = position("moving-second", 0, 0.0001, 1_000)
        third = position("moving-third", 0, 0.0002, 2_000)

        {:ok, candidate} =
          MotionTransition.evaluate(baseline["state"], second, policy, :replay, 1_000)

        {:ok, result} =
          MotionTransition.evaluate(candidate["state"], third, policy, :replay, 2_000)

        {result["state"], policy}

      "stationary" ->
        second = position("stationary-second", 0, 0, 1_000)
        third = position("stationary-third", 0, 0, 2_000)

        {:ok, candidate} =
          MotionTransition.evaluate(baseline["state"], second, policy, :replay, 1_000)

        {:ok, result} =
          MotionTransition.evaluate(candidate["state"], third, policy, :replay, 2_000)

        {result["state"], policy}
    end
  end

  defp motion_policy(changes \\ %{}) do
    {:ok, movement} =
      PositionMovement.new(%{
        id: "movement",
        revision: "movement-v1",
        order_policy: order_policy(),
        moving_speed_m_s: 1,
        stationary_speed_m_s: 0.1,
        moving_distance_m: 1,
        stationary_distance_m: 0.5,
        max_plausible_speed_m_s: 1_000,
        max_gap_ms: 10_000,
        uncertainty: :coordinate_only
      })

    {:ok, policy} =
      MotionTransition.new(
        Map.merge(
          %{
            id: "motion",
            revision: "motion-v1",
            movement_policy: movement,
            minimum_movement_ms: 1_000,
            minimum_stop_ms: 1_000
          },
          changes
        )
      )

    policy
  end

  defp order_policy do
    {:ok, policy} =
      PositionOrder.new(%{
        revision: "order-v1",
        event_time: :trusted_fix,
        future_skew_ms: 0,
        late_window_ms: 10_000,
        sequence: :none
      })

    policy
  end

  defp position(id, latitude, longitude, observed_at) do
    observation = observation("position-capture-#{id}", observed_at)

    {:ok, evidence} =
      Evidence.new(%{
        id: "position-#{id}",
        kind: :position,
        claim: %{
          "schema" => "wtr.position.v1",
          "latitude" => latitude,
          "longitude" => longitude,
          "altitude_m" => nil,
          "speed_m_s" => nil,
          "horizontal_accuracy_m" => nil,
          "accuracy_kind" => "unknown",
          "source" => "gnss",
          "fix_at" => observed_at,
          "device_at" => nil,
          "received_at" => observed_at,
          "fix_clock" => "trusted",
          "device_clock" => "unknown",
          "availability" => "available",
          "quality" => "valid",
          "source_units" => %{
            "latitude" => "degree",
            "longitude" => "degree",
            "altitude" => nil,
            "speed" => nil,
            "accuracy" => nil,
            "fix_time" => "unix-ms",
            "device_time" => nil,
            "receiver_time" => "unix-ms"
          },
          "conversion_revision" => "fixture-v1",
          "receiver_observation_id" => observation.id,
          "raw" => %{}
        },
        source_observation_ids: [observation.id],
        evidence_ids: [],
        profile: {"position", "1"},
        decoder: {"position", "1"},
        confidence: :exact,
        reasons: ["fixture"],
        association_id: nil
      })

    {:ok, bundle} = EvidenceBundle.new([observation], [evidence])
    {:ok, position} = Position.new(evidence.id, bundle)
    {:ok, sample} = PositionSample.new(position, bundle)
    sample
  end

  defp observation(id, observed_at),
    do: Fixtures.observation(%{id: id, observed_at: observed_at})
end
