defmodule Wotex.Tracker.GeofenceTransitionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Wotex.Tracker.{
    Evidence,
    EvidenceBundle,
    Fixtures,
    Geofence,
    GeofenceTransition,
    Position,
    PositionOrder,
    PositionSample
  }

  test "first certain membership is a baseline and unchanged membership advances without an event" do
    fence = fence()
    policy = policy()
    outside = sample("outside-1", 0, 0.002, 1_000)

    assert {:ok, baseline} =
             GeofenceTransition.evaluate(nil, fence, outside, policy, :live, 1_000)

    assert baseline["status"] == "baseline"
    assert baseline["reason"] == "initial_membership"
    assert baseline["event"] == nil
    assert baseline["membership"]["status"] == "outside"
    assert baseline["physical_action_dispatch"] == "none"
    assert {:ok, state} = GeofenceTransition.validate_state(baseline["state"])

    outside_again = sample("outside-2", 0, 0.003, 1_001)

    assert {:ok, stable} =
             GeofenceTransition.evaluate(state, fence, outside_again, policy, :live, 1_001)

    assert stable["status"] == "stable"
    assert stable["event"] == nil
    assert stable["state"].last_valid_sample.identity == outside_again.identity
    refute stable["state"].identity == state.identity

    assert {:ok, duplicate} =
             GeofenceTransition.evaluate(
               stable["state"],
               fence,
               outside_again,
               policy,
               :live,
               1_001
             )

    assert duplicate["status"] == "duplicate"
    assert duplicate["state"] === stable["state"]
    refute duplicate["state_changed"]
  end

  test "entry and exit retain both endpoints and have stable live/replay idempotency identity" do
    fence = fence()
    policy = policy()
    outside = sample("outside", 0, 0.002, 1_000)
    inside = sample("inside", 0, 0.0001, 1_001)

    {:ok, baseline} = GeofenceTransition.evaluate(nil, fence, outside, policy, :live, 1_000)

    assert {:ok, live} =
             GeofenceTransition.evaluate(
               baseline["state"],
               fence,
               inside,
               policy,
               :live,
               1_001
             )

    assert live["status"] == "transition"
    assert live["membership_changed"]
    assert live["event"]["kind"] == "geofence.entered"
    assert live["event"]["from_status"] == "outside"
    assert live["event"]["to_status"] == "inside"
    assert live["event"]["from_position_evidence_id"] == "outside"
    assert live["event"]["to_position_evidence_id"] == "inside"
    assert live["physical_action_dispatch"] == "separate_authorization_required"

    assert {:ok, replay} =
             GeofenceTransition.evaluate(
               baseline["state"],
               fence,
               inside,
               policy,
               :replay,
               1_001
             )

    assert replay["event"] === live["event"]
    assert replay["state"] === live["state"]
    assert replay["physical_action_dispatch"] == "prohibited"

    outside_again = sample("outside-again", 0, 0.002, 1_002)

    assert {:ok, exit} =
             GeofenceTransition.evaluate(
               live["state"],
               fence,
               outside_again,
               policy,
               :live,
               1_002
             )

    assert exit["event"]["kind"] == "geofence.exited"
    refute exit["event"]["id"] == live["event"]["id"]
  end

  test "closed policy, state and event documents restore exact geofence content" do
    fence = fence()
    policy = policy()
    outside = sample("serialized-outside", 0, 0.002, 1_000)
    inside = sample("serialized-inside", 0, 0, 1_001)

    {:ok, baseline} =
      GeofenceTransition.evaluate(nil, fence, outside, policy, :live, 1_000)

    {:ok, entered} =
      GeofenceTransition.evaluate(
        baseline["state"],
        fence,
        inside,
        policy,
        :live,
        1_001
      )

    {:ok, replay_entered} =
      GeofenceTransition.evaluate(
        baseline["state"],
        fence,
        inside,
        policy,
        :replay,
        1_001
      )

    assert {:ok, ^baseline} = GeofenceTransition.validate_transition(nil, baseline)

    assert {:ok, ^entered} =
             GeofenceTransition.validate_transition(baseline["state"], entered)

    assert {:ok, ^replay_entered} =
             GeofenceTransition.validate_transition(baseline["state"], replay_entered)

    assert :ok = GeofenceTransition.validate_event(entered["event"])
    assert {:ok, fence_document} = Geofence.to_map(fence)
    assert Geofence.from_map(fence_document) == {:ok, fence}
    assert {:ok, policy_document} = GeofenceTransition.to_map(policy)
    assert GeofenceTransition.from_map(policy_document) == {:ok, policy}
    assert {:ok, state_document} = GeofenceTransition.state_to_map(entered["state"])
    assert length(state_document["samples"]) == 1
    assert GeofenceTransition.state_from_map(state_document) == {:ok, entered["state"]}

    sample_document = hd(state_document["samples"])

    for changed <- [
          Map.put(state_document, "identity", "forged"),
          put_in(state_document, ["fence", "identity"], "forged"),
          put_in(state_document, ["policy", "identity"], "forged"),
          put_in(state_document, ["samples", Access.at(0), "identity"], "forged"),
          Map.put(state_document, "order_sample_identity", "missing"),
          Map.put(state_document, "order_sample_identity", nil),
          Map.update!(state_document, "samples", &(&1 ++ &1)),
          Map.put(state_document, "samples", List.duplicate(sample_document, 4)),
          Map.put(state_document, "schema", "wtr.geofence-state.v2"),
          Map.put(state_document, "extra", true)
        ] do
      assert {:error, _} = GeofenceTransition.state_from_map(changed)
    end

    for changed <- [
          Map.put(policy_document, "schema", "wtr.geofence-transition-policy.v2"),
          put_in(policy_document, ["order_policy", "identity"], "forged"),
          Map.put(policy_document, "order_policy_identity", "forged"),
          Map.put(policy_document, "identity", "forged"),
          Map.put(policy_document, "extra", true)
        ] do
      assert {:error, _} = GeofenceTransition.from_map(changed)
    end

    assert {:error, _} =
             GeofenceTransition.validate_transition(
               baseline["state"],
               put_in(entered, ["event", "reason"], "changed")
             )

    assert {:error, _} =
             GeofenceTransition.validate_transition(
               baseline["state"],
               Map.put(entered, "evaluated_at", 999)
             )

    for changed <- [
          Map.put(entered["event"], "schema", "wtr.geofence-event.v2"),
          Map.put(entered["event"], "kind", "geofence.guessed"),
          Map.put(entered["event"], "from_status", "uncertain"),
          Map.put(entered["event"], "event_at", nil),
          Map.put(entered["event"], "id", "forged"),
          Map.put(entered["event"], "extra", true)
        ] do
      assert {:error, _} = GeofenceTransition.validate_event(changed)
    end

    assert {:error, _} = GeofenceTransition.to_map(:invalid)
    assert {:error, _} = GeofenceTransition.from_map(nil)
    assert {:error, _} = GeofenceTransition.state_to_map(:invalid)
    assert {:error, _} = GeofenceTransition.state_from_map(nil)
    assert {:error, _} = GeofenceTransition.validate_transition(nil, nil)
  end

  test "uncertain samples advance ordering while the last valid membership is retained" do
    fence = fence(:require_bound)
    policy = policy()
    outside = sample("outside", 0, 0.002, 1_000, accuracy: 5)
    uncertain = sample("uncertain", 0, 0.0009, 1_001, accuracy: 20)
    inside = sample("inside", 0, 0.0001, 1_002, accuracy: 5)

    {:ok, baseline} = GeofenceTransition.evaluate(nil, fence, outside, policy, :live, 1_000)

    assert {:ok, unresolved} =
             GeofenceTransition.evaluate(
               baseline["state"],
               fence,
               uncertain,
               policy,
               :live,
               1_001
             )

    assert unresolved["status"] == "uncertain"
    assert unresolved["event"] == nil
    assert unresolved["state"].order_sample.identity == uncertain.identity
    assert unresolved["state"].last_received_sample.identity == uncertain.identity
    assert unresolved["state"].last_valid_sample.identity == outside.identity

    assert {:ok, entered} =
             GeofenceTransition.evaluate(
               unresolved["state"],
               fence,
               inside,
               policy,
               :live,
               1_002
             )

    assert entered["event"]["kind"] == "geofence.entered"
    assert entered["event"]["from_position_evidence_id"] == "outside"

    assert {:ok, initial_unknown} =
             GeofenceTransition.evaluate(nil, fence, uncertain, policy, :live, 1_001)

    assert initial_unknown["state"].last_valid_sample == nil

    assert {:ok, first_valid} =
             GeofenceTransition.evaluate(
               initial_unknown["state"],
               fence,
               inside,
               policy,
               :live,
               1_002
             )

    assert first_valid["status"] == "baseline"
    assert first_valid["event"] == nil
  end

  test "late reception advances last-received status without rewinding order or membership" do
    fence = fence()
    policy = policy(%{order_policy: order_policy(%{late_window_ms: 10})})
    outside = sample("outside", 0, 0.002, 1_000)
    late_inside = sample("late-inside", 0, 0, 999, received_at: 1_100)

    {:ok, baseline} = GeofenceTransition.evaluate(nil, fence, outside, policy, :live, 1_000)

    assert {:ok, historical} =
             GeofenceTransition.evaluate(
               baseline["state"],
               fence,
               late_inside,
               policy,
               :live,
               1_100
             )

    assert historical["status"] == "historical"
    assert historical["reason"] == "within_late_window"
    assert historical["event"] == nil
    assert historical["state"].order_sample.identity == outside.identity
    assert historical["state"].last_valid_sample.identity == outside.identity
    assert historical["state"].last_received_sample.identity == late_inside.identity
    assert historical["state"].last_received_outcome == "historical"
    assert historical["state_changed"]
  end

  test "transition gap equality emits while a larger gap establishes a new baseline" do
    fence = fence()
    policy = policy(%{max_transition_gap_ms: 10})
    outside = sample("outside", 0, 0.002, 1_000)
    at_limit = sample("at-limit", 0, 0, 1_010)
    beyond = sample("beyond", 0, 0, 1_011)

    {:ok, baseline} = GeofenceTransition.evaluate(nil, fence, outside, policy, :live, 1_000)

    assert {:ok, transition} =
             GeofenceTransition.evaluate(
               baseline["state"],
               fence,
               at_limit,
               policy,
               :live,
               1_010
             )

    assert transition["status"] == "transition"

    assert {:ok, rebaseline} =
             GeofenceTransition.evaluate(
               baseline["state"],
               fence,
               beyond,
               policy,
               :live,
               1_011
             )

    assert rebaseline["status"] == "baseline"
    assert rebaseline["reason"] == "transition_gap_exceeded"
    assert rebaseline["event"] == nil
    assert rebaseline["state"].last_valid_membership["status"] == "inside"
  end

  test "fence and rule edits recompute explicitly without inventing entry or exit" do
    old_fence = fence()
    new_fence = fence(:coordinate_only, %{revision: "yard-v2", radius_m: 300})
    old_policy = policy()
    outside = sample("outside", 0, 0.002, 1_000)

    {:ok, baseline} =
      GeofenceTransition.evaluate(nil, old_fence, outside, old_policy, :live, 1_000)

    assert {:ok, recomputed} =
             GeofenceTransition.evaluate(
               baseline["state"],
               new_fence,
               outside,
               old_policy,
               :live,
               1_000
             )

    assert recomputed["status"] == "recomputed"
    assert recomputed["reason"] == "fence_revised"
    assert recomputed["event"]["kind"] == "geofence.recomputed"
    assert recomputed["event"]["from_status"] == "outside"
    assert recomputed["event"]["to_status"] == "inside"
    assert recomputed["membership_changed"]

    new_policy = policy(%{revision: "rule-v2"})

    assert {:ok, rule_edit} =
             GeofenceTransition.evaluate(
               baseline["state"],
               old_fence,
               outside,
               new_policy,
               :live,
               1_000
             )

    assert rule_edit["reason"] == "rule_revised"
    assert rule_edit["event"]["kind"] == "geofence.recomputed"
    refute rule_edit["membership_changed"]
    refute rule_edit["event"]["id"] == recomputed["event"]["id"]
  end

  test "ordering conflicts, future samples and invalid scopes cannot alter canonical state" do
    required = order_policy(%{sequence: :required})
    policy = policy(%{order_policy: required})
    fence = fence()
    outside = sample("outside", 0, 0.002, 1_000, sequence: sequence(5))
    inside = sample("inside", 0, 0, 1_001, sequence: sequence(5))

    {:ok, baseline} = GeofenceTransition.evaluate(nil, fence, outside, policy, :live, 1_000)

    assert {:ok, conflict} =
             GeofenceTransition.evaluate(
               baseline["state"],
               fence,
               inside,
               policy,
               :live,
               1_001
             )

    assert conflict["status"] == "unknown"
    assert conflict["reason"] == "sequence_conflict"
    assert conflict["state"].last_valid_sample.identity == outside.identity
    assert conflict["event"] == nil

    future_policy = policy()
    future = sample("future", 0, 0, 2_000)

    assert {:ok, result} =
             GeofenceTransition.evaluate(nil, fence, future, future_policy, :live, 1_000)

    assert result["status"] == "unknown"
    assert result["state"] == nil

    other_fence = fence(:coordinate_only, %{id: "other"})
    other_policy = policy(%{id: "other"})

    assert {:error, %{code: :conflict}} =
             GeofenceTransition.evaluate(
               baseline["state"],
               other_fence,
               outside,
               policy,
               :live,
               1_000
             )

    assert {:error, %{code: :conflict}} =
             GeofenceTransition.evaluate(
               baseline["state"],
               fence,
               outside,
               other_policy,
               :live,
               1_000
             )

    assert {:error, _} =
             GeofenceTransition.evaluate(nil, fence, outside, future_policy, :invalid, 1_000)
  end

  test "policy and state identities reject modified nested values" do
    policy = policy()

    for change <- [
          %{id: "other"},
          %{revision: "other"},
          %{order_policy: order_policy(%{late_window_ms: 2})},
          %{max_transition_gap_ms: 0}
        ] do
      changed = policy(change)
      refute changed.identity == policy.identity
      assert {:error, %{code: :conflict}} = GeofenceTransition.validate(struct(policy, change))
    end

    for change <- [
          %{id: ""},
          %{revision: ""},
          %{order_policy: :invalid},
          %{max_transition_gap_ms: -1},
          %{max_transition_gap_ms: 604_800_001},
          %{extra: true}
        ] do
      assert {:error, _} = GeofenceTransition.new(Map.merge(policy_input(), change)),
             inspect(change)
    end

    sample = sample("outside", 0, 0.002, 1_000)

    {:ok, baseline} =
      GeofenceTransition.evaluate(nil, fence(), sample, policy, :live, 1_000)

    state = baseline["state"]

    assert {:error, %{code: :conflict}} =
             GeofenceTransition.validate_state(%{state | identity: "forged"})

    assert {:error, %{code: :conflict}} =
             GeofenceTransition.validate_state(%{
               state
               | last_valid_membership: Map.put(state.last_valid_membership, "status", "inside")
             })

    assert {:error, _} = GeofenceTransition.validate_state(:invalid)
    assert {:error, _} = GeofenceTransition.new(nil)
    assert {:error, _} = GeofenceTransition.validate(:invalid)
  end

  property "processing mode cannot change transition state or event identity" do
    check all(offset <- float(min: 0.001, max: 0.01)) do
      fence = fence()
      policy = policy()
      outside = sample("outside-#{offset}", 0, offset, 1_000)
      inside = sample("inside-#{offset}", 0, 0, 1_001)
      {:ok, baseline} = GeofenceTransition.evaluate(nil, fence, outside, policy, :live, 1_000)

      {:ok, live} =
        GeofenceTransition.evaluate(baseline["state"], fence, inside, policy, :live, 1_001)

      {:ok, replay} =
        GeofenceTransition.evaluate(
          baseline["state"],
          fence,
          inside,
          policy,
          :replay,
          1_001
        )

      assert live["event"] === replay["event"]
      assert live["state"] === replay["state"]
    end
  end

  defp fence(uncertainty \\ :coordinate_only, changes \\ %{}) do
    input = %{
      id: Map.get(changes, :id, "yard"),
      revision: Map.get(changes, :revision, "yard-v1"),
      shape: %{
        kind: :circle,
        latitude: 0,
        longitude: 0,
        radius_m: Map.get(changes, :radius_m, 100)
      },
      boundary: :inside,
      uncertainty: uncertainty
    }

    {:ok, value} = Geofence.new(input)
    value
  end

  defp policy(changes \\ %{}) do
    {:ok, value} = GeofenceTransition.new(Map.merge(policy_input(), changes))
    value
  end

  defp policy_input,
    do: %{
      id: "yard-membership",
      revision: "rule-v1",
      order_policy: order_policy(),
      max_transition_gap_ms: 60_000
    }

  defp order_policy(changes \\ %{}) do
    {:ok, value} =
      PositionOrder.new(
        Map.merge(
          %{
            revision: "order-v1",
            event_time: :trusted_fix,
            future_skew_ms: 0,
            late_window_ms: 60_000,
            sequence: :none
          },
          changes
        )
      )

    value
  end

  defp sequence(value),
    do: %{
      "schema" => "wtr.sequence.v1",
      "scope_id" => "device-a",
      "session_id" => "connection-a",
      "value" => value,
      "modulus" => 65_536,
      "receiver_observation_id" => "replaced"
    }

  defp sample(id, latitude, longitude, event_at, options \\ []) do
    received_at = Keyword.get(options, :received_at, event_at)
    observation = Fixtures.observation(%{id: "capture-" <> id, observed_at: received_at})
    sequence = Keyword.get(options, :sequence)
    sequence_id = if sequence, do: "sequence-" <> id, else: nil

    sequence_evidence =
      if sequence do
        {:ok, evidence} =
          Evidence.new(%{
            id: sequence_id,
            kind: :transport,
            claim: Map.put(sequence, "receiver_observation_id", observation.id),
            source_observation_ids: [observation.id],
            evidence_ids: [],
            profile: {"position", "1"},
            decoder: {"position", "1"},
            confidence: :exact,
            reasons: ["fixture"],
            association_id: nil
          })

        evidence
      end

    accuracy = Keyword.get(options, :accuracy)

    {:ok, position_evidence} =
      Evidence.new(%{
        id: id,
        kind: :position,
        claim: %{
          "schema" => "wtr.position.v1",
          "latitude" => latitude,
          "longitude" => longitude,
          "altitude_m" => nil,
          "speed_m_s" => nil,
          "horizontal_accuracy_m" => accuracy,
          "accuracy_kind" => if(is_nil(accuracy), do: "unknown", else: "bound"),
          "source" => "gnss",
          "fix_at" => event_at,
          "device_at" => nil,
          "received_at" => received_at,
          "fix_clock" => "trusted",
          "device_clock" => "unknown",
          "availability" => "available",
          "quality" => "valid",
          "source_units" => %{
            "latitude" => "degree",
            "longitude" => "degree",
            "altitude" => nil,
            "speed" => nil,
            "accuracy" => if(is_nil(accuracy), do: nil, else: "m"),
            "fix_time" => "unix-ms",
            "device_time" => nil,
            "receiver_time" => "unix-ms"
          },
          "conversion_revision" => "fixture-v1",
          "receiver_observation_id" => observation.id,
          "raw" => %{}
        },
        source_observation_ids: [observation.id],
        evidence_ids: if(sequence_id, do: [sequence_id], else: []),
        profile: {"position", "1"},
        decoder: {"position", "1"},
        confidence: :exact,
        reasons: ["fixture"],
        association_id: nil
      })

    evidence = Enum.reject([sequence_evidence, position_evidence], &is_nil/1)
    {:ok, bundle} = EvidenceBundle.new([observation], evidence)
    {:ok, position} = Position.new(id, bundle)
    {:ok, sample} = PositionSample.new(position, bundle, sequence_id)
    sample
  end
end
