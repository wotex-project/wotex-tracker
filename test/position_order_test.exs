defmodule Wotex.Tracker.PositionOrderTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Wotex.Tracker.{
    EvidenceBundle,
    Fixtures,
    Position,
    PositionOrder,
    PositionSample
  }

  test "sample binds optional sequence evidence to the same capture and position lineage" do
    sample = sample("one", 1_000, 1_000, sequence: sequence(7))

    assert {:ok, exported} = PositionSample.to_map(sample)
    assert exported["identity"] == sample.identity
    assert exported["sequence_evidence_id"] == "sequence-one"
    assert exported["sequence"]["scope_id"] == "device-a"
    assert exported["sequence"]["session_id"] == "connection-a"
    assert exported["sequence"]["value"] == 7
    assert {:ok, ^sample} = PositionSample.validate(sample)

    unsequenced = sample("one", 1_000, 1_000)
    refute unsequenced.identity == sample.identity
    assert unsequenced.sequence == nil

    assert {:error, %{code: :conflict}} =
             PositionSample.validate(%{sample | sequence: Map.put(sample.sequence, "value", 8)})

    assert {:error, _} = PositionSample.validate(:invalid)
    assert {:error, _} = PositionSample.to_map(:invalid)
  end

  test "sequence admission rejects unbound, cross-capture and malformed claims" do
    for change <- [
          %{"scope_id" => ""},
          %{"session_id" => ""},
          %{"value" => -1},
          %{"value" => 65_536},
          %{"modulus" => 2},
          %{"modulus" => 4_294_967_297},
          %{"schema" => "wtr.sequence.v2"},
          %{"extra" => true}
        ] do
      {position, bundle} = position_bundle("bad", 1_000, 1_000, Map.merge(sequence(1), change))
      assert {:error, _} = PositionSample.new(position, bundle, "sequence-bad"), inspect(change)
    end

    {position, bundle} =
      position_bundle("cross-capture", 1_000, 1_000, sequence(1),
        sequence_receiver: "other-capture"
      )

    assert {:error, %{code: :conflict}} =
             PositionSample.new(position, bundle, "sequence-cross-capture")

    {position, bundle} = position_bundle("unbound", 1_000, 1_000, sequence(1), parent: false)
    assert {:error, %{code: :conflict}} = PositionSample.new(position, bundle, "sequence-unbound")

    assert {:error, %{code: :dangling_reference}} =
             PositionSample.new(position, bundle, "missing")

    assert {:error, _} = PositionSample.new(position, bundle, 123)
  end

  test "event time is qualified explicitly and initial or duplicate disposition is stable" do
    strict = policy()
    first = sample("first", 1_000, 1_010)

    assert {:ok, result} = PositionOrder.evaluate(first, nil, strict, 1_010)
    assert result["status"] == "accepted"
    assert result["reason"] == "initial"
    assert result["disposition"] == "advance"
    assert result["event_time_basis"] == "fix"
    assert result["event_at"] == 1_000

    assert {:ok, duplicate} = PositionOrder.evaluate(first, first, strict, 1_010)
    assert duplicate["status"] == "duplicate"
    assert duplicate["disposition"] == "ignore"

    missing = sample("missing", nil, 1_000, fix_clock: "unknown")
    assert {:ok, unknown} = PositionOrder.evaluate(missing, nil, strict, 1_000)
    assert unknown["reason"] == "missing_fix_time"

    fallback = policy(%{event_time: :trusted_fix_or_receiver})
    assert {:ok, accepted} = PositionOrder.evaluate(missing, nil, fallback, 1_000)
    assert accepted["event_time_basis"] == "receiver"
    assert accepted["event_at"] == 1_000

    untrusted = sample("untrusted", 999, 1_000, fix_clock: "untrusted")
    assert {:ok, result} = PositionOrder.evaluate(untrusted, nil, fallback, 1_000)
    assert result["reason"] == "untrusted_fix_clock"

    for {value, now, reason} <- [
          {sample("receiver-future", 1_000, 1_003), 1_000, "receiver_in_future"},
          {sample("fix-future", 1_003, 1_003), 1_000, "receiver_in_future"},
          {sample("fix-after", 1_003, 1_000), 1_000, "fix_after_reception"}
        ] do
      assert {:ok, decision} = PositionOrder.evaluate(value, nil, strict, now)
      assert decision["status"] == "unknown"
      assert decision["reason"] == reason
    end
  end

  test "repeated timestamps use a complete tie key and late windows never silently rewind" do
    earlier = sample("a", 1_000, 1_010)
    later = sample("b", 1_000, 1_010)
    policy = policy(%{late_window_ms: 10})

    assert {:ok, forward} = PositionOrder.evaluate(later, earlier, policy, 1_010)
    assert forward["status"] == "accepted"
    assert forward["order_key"] > order(earlier, policy, 1_010)

    assert {:ok, tied_late} = PositionOrder.evaluate(earlier, later, policy, 1_010)
    assert tied_late["status"] == "historical"
    assert tied_late["reason"] == "within_late_window"
    assert tied_late["late_by_ms"] == 0
    assert tied_late["disposition"] == "recompute_history"

    within = sample("within", 995, 1_020)
    assert {:ok, result} = PositionOrder.evaluate(within, later, policy, 1_020)
    assert result["reason"] == "within_late_window"
    assert result["late_by_ms"] == 5

    expired = sample("expired", 989, 1_020)
    assert {:ok, result} = PositionOrder.evaluate(expired, later, policy, 1_020)
    assert result["reason"] == "late_window_exceeded"
    assert result["late_by_ms"] == 11
    assert result["disposition"] == "history_only"
  end

  test "sequence comparison distinguishes wrap, reset, scope, conflicts and ambiguous half ranges" do
    policy = policy(%{sequence: :required})
    previous = sample("previous", 1_000, 1_000, sequence: sequence(65_534))

    cases = [
      {sample("wrap", 1_001, 1_001, sequence: sequence(1)), "accepted", "sequence_wrapped"},
      {sample("advance", 1_001, 1_001, sequence: sequence(65_535)), "accepted",
       "sequence_advanced"},
      {sample("reset", 1_001, 1_001, sequence: sequence(0, session: "connection-b")), "accepted",
       "session_reset"},
      {sample("scope", 1_001, 1_001, sequence: sequence(65_534, scope: "device-b")), "accepted",
       "distinct_scope"},
      {sample("same", 1_001, 1_001, sequence: sequence(65_534)), "unknown", "sequence_conflict"},
      {sample("older", 1_001, 1_001, sequence: sequence(65_000)), "unknown", "sequence_older"},
      {sample("half", 1_001, 1_001, sequence: sequence(32_766)), "unknown", "sequence_ambiguous"},
      {sample("modulus", 1_001, 1_001, sequence: sequence(1, modulus: 65_535)), "unknown",
       "modulus_changed"}
    ]

    for {current, status, relation} <- cases do
      assert {:ok, result} = PositionOrder.evaluate(current, previous, policy, 1_001)
      assert result["status"] == status
      assert result["sequence_relation"] == relation
    end
  end

  test "sequence policy makes omission and use deliberate" do
    unsequenced = sample("plain", 1_000, 1_000)
    sequenced = sample("sequenced", 1_000, 1_000, sequence: sequence(1))

    assert {:ok, %{"reason" => "missing_sequence"}} =
             PositionOrder.evaluate(unsequenced, nil, policy(%{sequence: :required}), 1_000)

    assert {:ok, %{"reason" => "sequence_disabled"}} =
             PositionOrder.evaluate(sequenced, nil, policy(%{sequence: :none}), 1_000)

    assert {:ok, %{"status" => "accepted"}} =
             PositionOrder.evaluate(unsequenced, nil, policy(%{sequence: :optional}), 1_000)

    assert {:error, _} = PositionOrder.evaluate(:invalid, nil, policy(), 1_000)
    assert {:error, _} = PositionOrder.evaluate(unsequenced, :invalid, policy(), 1_000)
    assert {:error, _} = PositionOrder.evaluate(unsequenced, nil, :invalid, 1_000)
    assert {:error, _} = PositionOrder.evaluate(unsequenced, nil, policy(), 1_000.0)
  end

  test "policy identity fixes every ordering choice and rejects malformed windows" do
    original = policy()

    for change <- [
          %{revision: "other"},
          %{event_time: :trusted_fix_or_receiver},
          %{future_skew_ms: 2},
          %{late_window_ms: 20},
          %{sequence: :required}
        ] do
      changed = policy(change)
      refute changed.identity == original.identity
      assert {:error, %{code: :conflict}} = PositionOrder.validate(struct(original, change))
    end

    for change <- [
          %{revision: ""},
          %{event_time: :device},
          %{future_skew_ms: -1},
          %{future_skew_ms: 604_800_001},
          %{late_window_ms: -1},
          %{late_window_ms: 604_800_001},
          %{sequence: :guess},
          %{extra: true}
        ] do
      assert {:error, _} = PositionOrder.new(Map.merge(policy_input(), change)), inspect(change)
    end

    assert {:error, _} = PositionOrder.new(nil)
    assert {:error, _} = PositionOrder.validate(:invalid)
  end

  property "modular increments below half-range always advance, including wrap" do
    check all(previous <- integer(0..65_535), increment <- integer(1..32_767)) do
      current = Integer.mod(previous + increment, 65_536)
      older = sample("p#{previous}", 1_000, 1_000, sequence: sequence(previous))
      newer = sample("c#{previous}-#{increment}", 1_001, 1_001, sequence: sequence(current))

      assert {:ok, result} =
               PositionOrder.evaluate(newer, older, policy(%{sequence: :required}), 1_001)

      assert result["status"] == "accepted"
      assert result["sequence_relation"] in ["sequence_advanced", "sequence_wrapped"]
    end
  end

  defp order(sample, policy, now) do
    {:ok, result} = PositionOrder.evaluate(sample, nil, policy, now)
    result["order_key"]
  end

  defp policy(changes \\ %{}) do
    {:ok, value} = PositionOrder.new(Map.merge(policy_input(), changes))
    value
  end

  defp policy_input,
    do: %{
      revision: "order-v1",
      event_time: :trusted_fix,
      future_skew_ms: 1,
      late_window_ms: 10,
      sequence: :none
    }

  defp sequence(value, options \\ []) do
    %{
      "schema" => "wtr.sequence.v1",
      "scope_id" => Keyword.get(options, :scope, "device-a"),
      "session_id" => Keyword.get(options, :session, "connection-a"),
      "value" => value,
      "modulus" => Keyword.get(options, :modulus, 65_536),
      "receiver_observation_id" => "replaced"
    }
  end

  defp sample(id, fix_at, received_at, options \\ []) do
    sequence = Keyword.get(options, :sequence)
    {position, bundle} = position_bundle(id, fix_at, received_at, sequence, options)
    sequence_id = if sequence, do: "sequence-" <> id, else: nil
    {:ok, sample} = PositionSample.new(position, bundle, sequence_id)
    sample
  end

  defp position_bundle(id, fix_at, received_at, sequence, options \\ []) do
    observation = Fixtures.observation(%{id: "capture-" <> id, observed_at: received_at})

    sequence_receiver = Keyword.get(options, :sequence_receiver, observation.id)

    sequence =
      if sequence,
        do: Map.put(sequence, "receiver_observation_id", sequence_receiver),
        else: nil

    sequence_observation =
      if sequence && sequence_receiver != observation.id,
        do: Fixtures.observation(%{id: sequence_receiver, observed_at: received_at}),
        else: nil

    sequence_evidence =
      if sequence do
        Fixtures.evidence(%{
          id: "sequence-" <> id,
          kind: :transport,
          claim: sequence,
          source_observation_ids: [sequence_receiver],
          evidence_ids: [],
          profile: {"position", "1"},
          decoder: {"position", "1"}
        })
      end

    parents =
      if sequence_evidence && Keyword.get(options, :parent, true),
        do: [sequence_evidence.id],
        else: []

    units = %{
      "latitude" => "degree",
      "longitude" => "degree",
      "altitude" => nil,
      "speed" => nil,
      "accuracy" => nil,
      "fix_time" => if(is_nil(fix_at), do: nil, else: "unix-ms"),
      "device_time" => nil,
      "receiver_time" => "unix-ms"
    }

    position_evidence =
      Fixtures.evidence(%{
        id: id,
        kind: :position,
        claim: %{
          "schema" => "wtr.position.v1",
          "latitude" => 59.3293,
          "longitude" => 18.0686,
          "altitude_m" => nil,
          "speed_m_s" => nil,
          "horizontal_accuracy_m" => nil,
          "accuracy_kind" => "unknown",
          "source" => "gnss",
          "fix_at" => fix_at,
          "device_at" => nil,
          "received_at" => received_at,
          "fix_clock" => Keyword.get(options, :fix_clock, "trusted"),
          "device_clock" => "unknown",
          "availability" => "available",
          "quality" => "valid",
          "source_units" => units,
          "conversion_revision" => "fixture-v1",
          "receiver_observation_id" => observation.id,
          "raw" => %{}
        },
        source_observation_ids: [observation.id],
        evidence_ids: parents,
        profile: {"position", "1"},
        decoder: {"position", "1"}
      })

    evidence = Enum.reject([sequence_evidence, position_evidence], &is_nil/1)
    observations = Enum.reject([observation, sequence_observation], &is_nil/1)
    {:ok, bundle} = EvidenceBundle.new(observations, evidence)
    {:ok, position} = Position.new(id, bundle)
    {position, bundle}
  end
end
