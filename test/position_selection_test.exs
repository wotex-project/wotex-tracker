defmodule Wotex.Tracker.PositionSelectionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Wotex.Tracker.{
    Evidence,
    EvidenceBundle,
    Fixtures,
    Position,
    PositionFreshness,
    PositionSelection
  }

  test "freshness, source, quality, accuracy, time and IDs form one total deterministic order" do
    candidates = [
      candidate("stale-gnss", %{"source" => "gnss", "fix_at" => 900}),
      candidate("fresh-ble", %{
        "source" => "ble",
        "horizontal_accuracy_m" => 1,
        "accuracy_kind" => "bound"
      }),
      candidate("fresh-wifi", %{
        "source" => "wifi",
        "horizontal_accuracy_m" => 50,
        "accuracy_kind" => "bound"
      })
    ]

    selection = policy(%{accepted_freshness: [:fresh, :stale]})
    freshness = freshness_policy()

    for permutation <- permutations(candidates) do
      assert {:ok, result} = PositionSelection.select(permutation, selection, freshness, 1000)
      assert result["status"] == "selected"
      assert result["selected"]["evidence_id"] == "fresh-wifi"
      assert result["qualified_count"] == 3
      assert result["rejected"] == []

      assert result["selected"]["rank"] == [
               0,
               1,
               0,
               50,
               -1000,
               -1000,
               "fresh-wifi",
               result["selected"]["bundle_identity"]
             ]

      assert result["policy_identity"] == selection.identity
      assert result["freshness_policy_identity"] == freshness.identity
    end

    same_source = [
      candidate("suspect", %{
        "quality" => "suspect",
        "horizontal_accuracy_m" => 0,
        "accuracy_kind" => "bound"
      }),
      candidate("valid-wide", %{"horizontal_accuracy_m" => 20, "accuracy_kind" => "bound"}),
      candidate("valid-precise-old", %{
        "horizontal_accuracy_m" => 10,
        "accuracy_kind" => "bound",
        "fix_at" => 999
      }),
      candidate("valid-precise-new-b", %{
        "horizontal_accuracy_m" => 10,
        "accuracy_kind" => "bound"
      }),
      candidate("valid-precise-new-a", %{
        "horizontal_accuracy_m" => 10,
        "accuracy_kind" => "bound"
      })
    ]

    assert {:ok, result} = PositionSelection.select(same_source, selection, freshness, 1000)
    assert result["selected"]["evidence_id"] == "valid-precise-new-a"
  end

  test "freshness is recomputed from immutable evidence and delayed delivery cannot win" do
    old_delayed =
      candidate("old-delayed", %{"source" => "gnss", "fix_at" => 900, "received_at" => 1000})

    recent = candidate("recent", %{"source" => "cellular", "fix_at" => 995, "received_at" => 995})

    assert {:ok, result} =
             PositionSelection.select([old_delayed, recent], policy(), freshness_policy(), 1000)

    assert result["selected"]["evidence_id"] == "recent"

    assert Enum.map(result["rejected"], &Map.delete(&1, "bundle_identity")) == [
             %{"evidence_id" => "old-delayed", "reason" => "freshness:stale"}
           ]

    forged = %{old_delayed.position | claim: Map.put(old_delayed.position.claim, "fix_at", 1000)}

    assert {:error, %{code: :conflict}} =
             PositionSelection.select(
               [%{old_delayed | position: forged}],
               policy(),
               freshness_policy(),
               1000
             )
  end

  test "missing accuracy, unlisted sources, accuracy ceilings and unknown freshness are explicit" do
    candidates = [
      candidate("missing", %{}),
      candidate("unlisted", %{
        "source" => "operator",
        "horizontal_accuracy_m" => 1,
        "accuracy_kind" => "bound"
      }),
      candidate("imprecise", %{"horizontal_accuracy_m" => 101, "accuracy_kind" => "bound"}),
      candidate("unavailable", %{
        "availability" => "unavailable",
        "quality" => "unavailable",
        "latitude" => nil,
        "longitude" => nil,
        "fix_at" => nil,
        "fix_clock" => "unknown"
      })
    ]

    strict =
      policy(%{
        missing_accuracy: :reject,
        unlisted_sources: :reject,
        max_horizontal_accuracy_m: 100
      })

    assert {:ok, result} = PositionSelection.select(candidates, strict, freshness_policy(), 1000)
    assert result["status"] == "unknown"
    assert result["selected"] == nil
    assert result["qualified_count"] == 0

    assert Enum.map(result["rejected"], &Map.delete(&1, "bundle_identity")) == [
             %{"evidence_id" => "imprecise", "reason" => "accuracy_limit"},
             %{"evidence_id" => "missing", "reason" => "missing_accuracy"},
             %{"evidence_id" => "unavailable", "reason" => "freshness:unknown"},
             %{"evidence_id" => "unlisted", "reason" => "unlisted_source"}
           ]

    permissive =
      policy(%{missing_accuracy: :first, unlisted_sources: :last, max_horizontal_accuracy_m: nil})

    assert {:ok, result} =
             PositionSelection.select(candidates, permissive, freshness_policy(), 1000)

    assert result["selected"]["evidence_id"] == "missing"
    assert result["qualified_count"] == 3
  end

  test "policy identity binds every field and malformed policies fail before candidates" do
    original = policy()

    for change <- [
          %{revision: "other"},
          %{accepted_freshness: [:fresh, :stale]},
          %{source_priority: [:cellular, :gnss, :wifi, :ble]},
          %{unlisted_sources: :last},
          %{missing_accuracy: :first},
          %{max_horizontal_accuracy_m: 0}
        ] do
      changed = policy(change)
      refute changed.identity == original.identity
      assert {:error, %{code: :conflict}} = PositionSelection.validate(struct(original, change))
    end

    invalid = [
      %{revision: ""},
      %{accepted_freshness: []},
      %{accepted_freshness: [:unknown]},
      %{accepted_freshness: [:fresh, :fresh]},
      %{source_priority: []},
      %{source_priority: [:gnss, :gnss]},
      %{source_priority: [:satellite]},
      %{unlisted_sources: :accept},
      %{missing_accuracy: :unknown},
      %{max_horizontal_accuracy_m: -1},
      %{max_horizontal_accuracy_m: 40_100_001},
      %{max_horizontal_accuracy_m: "10"},
      %{extra: true}
    ]

    for change <- invalid do
      assert {:error, _} = PositionSelection.new(Map.merge(policy_input(), change)),
             inspect(change)
    end

    assert {:error, _} = PositionSelection.new(nil)
    assert {:error, _} = PositionSelection.validate(:invalid)
    assert {:error, _} = PositionSelection.select([], :invalid, freshness_policy(), 1000)
    assert {:error, _} = PositionSelection.select([], original, :invalid, 1000)
    assert {:error, _} = PositionSelection.select([], original, freshness_policy(), 1000.0)
    assert {:error, _} = PositionSelection.select([%{}], original, freshness_policy(), 1000)
    assert {:error, _} = PositionSelection.select(:improper, original, freshness_policy(), 1000)
  end

  test "candidate admission is bounded at 64 and never silently truncates a tie" do
    candidates =
      for id <- 1..64, do: candidate(String.pad_leading(Integer.to_string(id), 2, "0"), %{})

    assert {:ok, result} =
             PositionSelection.select(candidates, policy(), freshness_policy(), 1000)

    assert result["qualified_count"] == 64
    assert result["selected"]["evidence_id"] == "01"

    assert {:error, %{code: :limit_exceeded}} =
             PositionSelection.select(
               candidates ++ [candidate("65", %{})],
               policy(),
               freshness_policy(),
               1000
             )

    duplicate = hd(candidates)

    assert {:error, %{code: :duplicate_id}} =
             PositionSelection.select(
               [duplicate, duplicate],
               policy(),
               freshness_policy(),
               1000
             )
  end

  property "candidate order cannot change a fully tied selection" do
    check all(
            ids <-
              uniq_list_of(string(:alphanumeric, min_length: 1, max_length: 8),
                min_length: 1,
                max_length: 20
              )
          ) do
      candidates = Enum.map(ids, &candidate(&1, %{}))
      {:ok, forward} = PositionSelection.select(candidates, policy(), freshness_policy(), 1000)

      {:ok, reverse} =
        PositionSelection.select(Enum.reverse(candidates), policy(), freshness_policy(), 1000)

      assert forward["selected"]["evidence_id"] == Enum.min(ids)
      assert forward["selected"] == reverse["selected"]
    end
  end

  defp candidate(id, change) do
    claim = Map.merge(claim(), change)

    claim =
      if is_number(claim["horizontal_accuracy_m"]) and not Map.has_key?(change, "source_units") do
        Map.update!(claim, "source_units", &Map.put(&1, "accuracy", "m"))
      else
        claim
      end

    received = if is_integer(claim["received_at"]), do: claim["received_at"], else: 1000
    observation = Fixtures.observation(%{id: "capture-" <> id, observed_at: received})
    claim = Map.put(claim, "receiver_observation_id", observation.id)

    {:ok, evidence} =
      Evidence.new(%{
        id: id,
        kind: :position,
        claim: claim,
        source_observation_ids: [observation.id],
        evidence_ids: [],
        profile: {"position", "1"},
        decoder: {"position", "1"},
        confidence: :exact,
        reasons: ["fixture"],
        association_id: nil
      })

    {:ok, bundle} = EvidenceBundle.new([observation], [evidence])
    {:ok, position} = Position.new(id, bundle)
    %{position: position, bundle: bundle}
  end

  defp claim,
    do: %{
      "schema" => "wtr.position.v1",
      "latitude" => 59.3293,
      "longitude" => 18.0686,
      "altitude_m" => nil,
      "speed_m_s" => 0.0,
      "horizontal_accuracy_m" => nil,
      "accuracy_kind" => "unknown",
      "source" => "gnss",
      "fix_at" => 1000,
      "device_at" => nil,
      "received_at" => 1000,
      "fix_clock" => "trusted",
      "device_clock" => "unknown",
      "availability" => "available",
      "quality" => "valid",
      "source_units" => %{
        "latitude" => "degree",
        "longitude" => "degree",
        "altitude" => nil,
        "speed" => "m/s",
        "accuracy" => nil,
        "fix_time" => "unix-ms",
        "device_time" => nil,
        "receiver_time" => "unix-ms"
      },
      "conversion_revision" => "fixture-v1",
      "receiver_observation_id" => "replaced",
      "raw" => %{}
    }

  defp policy_input(change \\ %{}),
    do:
      Map.merge(
        %{
          revision: "selection-v1",
          accepted_freshness: [:fresh],
          source_priority: [:gnss, :wifi, :cellular, :ble],
          unlisted_sources: :reject,
          missing_accuracy: :last,
          max_horizontal_accuracy_m: nil
        },
        change
      )

  defp policy(change \\ %{}) do
    {:ok, value} = PositionSelection.new(policy_input(change))
    value
  end

  defp freshness_policy do
    {:ok, value} =
      PositionFreshness.new(%{
        revision: "freshness-v1",
        max_age_ms: 10,
        future_skew_ms: 0,
        missing_fix: :unknown,
        accept_suspect: true
      })

    value
  end

  defp permutations([a, b, c]),
    do: [[a, b, c], [a, c, b], [b, a, c], [b, c, a], [c, a, b], [c, b, a]]
end
