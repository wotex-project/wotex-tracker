defmodule Wotex.Tracker.RouteReplayTest do
  use ExUnit.Case, async: true

  alias Wotex.Tracker.{
    Evidence,
    EvidenceBundle,
    Fixtures,
    Position,
    PositionSample,
    RouteReplay
  }

  test "orders exact points deterministically and crosses the antimeridian without a false gap" do
    a = sample("a", 0, 179.999, 1_000)
    b = sample("b", 0, -179.999, 1_000)
    policy = policy(%{max_gap_m: 500})

    assert {:ok, forward} = RouteReplay.evaluate([b, a], policy)
    assert {:ok, reverse} = RouteReplay.evaluate([a, b], policy)
    assert forward == reverse
    assert forward["status"] == "complete"
    assert forward["segment_count"] == 1
    assert forward["breaks"] == []
    assert forward["rejected"] == []

    [segment] = forward["segments"]
    assert Enum.map(segment["points"], & &1["position_evidence_id"]) == ~w(a b)
    assert hd(segment["points"])["latitude"] === 0
    assert hd(segment["points"])["longitude"] === 179.999
  end

  test "never bridges rejected positions or excessive time and distance gaps" do
    values = [
      sample("a", 0, 0, 1_000),
      sample("suspect", 0, 0.001, 1_100, quality: "suspect"),
      sample("b", 0, 0.002, 1_200),
      sample("c", 0, 0.003, 2_500),
      sample("d", 0, 1, 2_600)
    ]

    assert {:ok, route} = RouteReplay.evaluate(Enum.reverse(values), policy())
    assert route["status"] == "partial"
    assert route["reason"] == "gaps_or_rejections"
    assert route["sample_count"] == 5
    assert route["point_count"] == 4
    assert route["segment_count"] == 4
    assert route["break_count"] == 3
    assert route["rejected_count"] == 1
    assert route["policy"]["max_gap_ms"] == 1_000
    assert route["policy"]["max_gap_m"] == 1_000
    assert route["policy"]["identity"] == policy().identity

    assert Enum.map(route["breaks"], & &1["reason"]) ==
             ~w(rejected_samples time_gap distance_gap)

    [rejected] = route["rejected"]
    assert rejected["position_evidence_id"] == "suspect"
    assert rejected["reason"] == "quality:suspect"

    [first_break | _] = route["breaks"]
    assert first_break["after_sample_identity"] == hd(values).identity
    assert first_break["before_sample_identity"] == Enum.at(values, 2).identity
    assert first_break["rejected_sample_identities"] == [Enum.at(values, 1).identity]
    assert first_break["gap_ms"] == 200
    assert first_break["center_distance_m"] > 0
  end

  test "receiver fallback is explicit and an untrusted supplied fix never falls back" do
    missing =
      sample("missing", 0, 0, 1_000,
        fix_at: nil,
        fix_clock: "unknown"
      )

    untrusted = sample("untrusted", 0, 0.001, 1_100, fix_clock: "untrusted")
    future_fix = sample("future-fix", 0, 0.002, 1_200, fix_at: 1_201)

    assert {:ok, fallback} =
             RouteReplay.evaluate([missing], policy(%{event_time: :trusted_fix_or_receiver}))

    [point] = hd(fallback["segments"])["points"]
    assert point["event_at"] == 1_000
    assert point["event_time_basis"] == "receiver"

    assert {:ok, strict} = RouteReplay.evaluate([missing], policy())
    assert strict["status"] == "empty"
    assert hd(strict["rejected"])["reason"] == "missing_fix_time"

    assert {:ok, refused} =
             RouteReplay.evaluate([untrusted], policy(%{event_time: :trusted_fix_or_receiver}))

    assert refused["status"] == "empty"
    assert hd(refused["rejected"])["reason"] == "untrusted_fix_clock"

    assert {:ok, refused} = RouteReplay.evaluate([future_fix], policy())
    assert hd(refused["rejected"])["reason"] == "fix_after_reception"
  end

  test "unavailable positions are disclosed and valid zero coordinates are retained" do
    unavailable =
      sample("unavailable", nil, nil, 900,
        availability: "unavailable",
        quality: "unavailable"
      )

    zero = sample("zero", 0, 0, 1_000)

    assert {:ok, route} = RouteReplay.evaluate([zero, unavailable], policy())
    assert route["point_count"] == 1
    assert route["rejected_count"] == 1
    assert hd(route["rejected"])["reason"] == "unavailable"
    assert hd(hd(route["segments"])["points"])["latitude"] === 0
  end

  test "policy identity and sample bounds fail closed" do
    original = policy()

    for change <- [
          %{revision: "other"},
          %{event_time: :trusted_fix_or_receiver},
          %{qualities: [:valid, :suspect]},
          %{max_gap_ms: 2_000},
          %{max_gap_m: 2_000},
          %{max_samples: 8}
        ] do
      changed = policy(change)
      refute changed.identity == original.identity
      assert {:error, %{code: :conflict}} = RouteReplay.validate(struct(original, change))
    end

    for change <- [
          %{id: ""},
          %{event_time: :device},
          %{qualities: []},
          %{qualities: [:valid, :valid]},
          %{qualities: [:unavailable]},
          %{max_gap_ms: 0},
          %{max_gap_ms: 2_678_400_001},
          %{max_gap_m: 0},
          %{max_gap_m: 40_100_001},
          %{max_samples: 0},
          %{max_samples: 257},
          %{extra: true}
        ] do
      assert {:error, _} = RouteReplay.new(Map.merge(policy_input(), change)), inspect(change)
    end

    one = sample("one", 0, 0, 1_000)
    assert {:error, %{code: :duplicate_id}} = RouteReplay.evaluate([one, one], original)
    assert {:error, _} = RouteReplay.evaluate([:invalid], original)
    assert {:error, _} = RouteReplay.evaluate(:invalid, original)
    assert {:error, _} = RouteReplay.evaluate([one], :invalid)
    assert {:error, _} = RouteReplay.validate(:invalid)

    assert {:ok, bounded} = RouteReplay.new(%{policy_input() | max_samples: 1})
    assert {:error, _} = RouteReplay.evaluate([one, sample("two", 0, 0.001, 1_001)], bounded)
  end

  defp policy(changes \\ %{}) do
    {:ok, policy} = RouteReplay.new(Map.merge(policy_input(), changes))
    policy
  end

  defp policy_input do
    %{
      id: "route-page",
      revision: "fixture-v1",
      event_time: :trusted_fix,
      qualities: [:valid],
      max_gap_ms: 1_000,
      max_gap_m: 1_000,
      max_samples: 16
    }
  end

  defp sample(id, latitude, longitude, received_at, options \\ []) do
    availability = Keyword.get(options, :availability, "available")
    quality = Keyword.get(options, :quality, "valid")
    fix_at = Keyword.get(options, :fix_at, received_at)
    fix_clock = Keyword.get(options, :fix_clock, "trusted")
    accuracy = Keyword.get(options, :accuracy)
    observation = Fixtures.observation(%{id: "capture-" <> id, observed_at: received_at})

    units = %{
      "latitude" => if(is_nil(latitude), do: nil, else: "degree"),
      "longitude" => if(is_nil(longitude), do: nil, else: "degree"),
      "altitude" => nil,
      "speed" => nil,
      "accuracy" => if(is_nil(accuracy), do: nil, else: "m"),
      "fix_time" => if(is_nil(fix_at), do: nil, else: "unix-ms"),
      "device_time" => nil,
      "receiver_time" => "unix-ms"
    }

    {:ok, evidence} =
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
          "fix_at" => fix_at,
          "device_at" => nil,
          "received_at" => received_at,
          "fix_clock" => fix_clock,
          "device_clock" => "unknown",
          "availability" => availability,
          "quality" => quality,
          "source_units" => units,
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
    {:ok, position} = Position.new(id, bundle)
    {:ok, sample} = PositionSample.new(position, bundle)
    sample
  end
end
