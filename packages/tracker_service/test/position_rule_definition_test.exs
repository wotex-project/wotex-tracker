defmodule Wotex.Tracker.Service.PositionRuleDefinitionTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import Wotex.Tracker.Service.Fixtures

  alias Wotex.Tracker
  alias Wotex.Tracker.Decoders.RuuviRawV2
  alias Wotex.Tracker.Evidence
  alias Wotex.Tracker.EvidenceBundle
  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.{Identifier, RuleEvaluation}

  setup do
    context = service()
    {:ok, profile} = RuuviRawV2.profile()
    revision = {"fixture.position-rules", "1.0.0"}
    profile = %{profile | id: elem(revision, 0), version: elem(revision, 1), decoder: revision}
    {:ok, catalogue} = Tracker.catalogue([profile])

    callback = fn observation ->
      {:ok, decoded} = RuuviRawV2.decode(observation)
      {:ok, %{decoded | positions: [position_claim(observation)]}}
    end

    {:ok, configured} =
      Service.new(%{
        store: context.store,
        credentials: context.credentials,
        base_url: context.service.base_url,
        catalogue: catalogue,
        model: context.service.model,
        decoders: [{revision, callback}]
      })

    context = Map.put(context, :service, configured)
    {thing, _td} = materialized(context)
    Map.put(context, :thing, thing)
  end

  test "position definitions drive geofence and motion state from materialisations", c do
    assert {:ok, %{"generation" => "4"}} = save(c, geofence(c.thing, "3"))
    assert {:ok, %{"generation" => "5"}} = save(c, motion(c.thing, "4"))

    assert {:ok, %{"value" => %{"status" => "outside"}}} =
             rule(c, "geofence:yard")

    assert {:ok, %{"value" => %{"status" => "unknown", "motion" => initial}}} =
             rule(c, "motion:movement")

    assert initial["candidate_status"] == nil
    assert initial["active_trip"] == nil

    assert {:ok, %{"generation" => "8"}} =
             materialize_position(c, "inside", c.now + 1_000, "5")

    assert {:ok, %{"value" => %{"status" => "inside"}}} =
             rule(c, "geofence:yard")

    assert {:ok, %{"value" => %{"status" => "unknown", "motion" => candidate}}} =
             rule(c, "motion:movement")

    assert candidate["candidate_status"] == "moving"
    assert candidate["candidate_since"] == %{"type" => "integer", "value" => c.now + 1_000}

    assert {:ok, %{"generation" => "11"}} =
             materialize_position(c, "outside-2", c.now + 2_000, "8")

    assert {:ok, %{"value" => %{"status" => "moving", "motion" => moving}}} =
             rule(c, "motion:movement")

    assert %{"id" => trip_id} = moving["active_trip"]
    assert is_binary(trip_id)

    assert {:ok, %{"value" => %{"status" => "outside"}}} =
             rule(c, "geofence:yard")

    assert {:ok, %{"items" => alerts}} =
             Service.list(c.service, c.reader, c.scope, "alerts", %{}, c.now + 2_000)

    assert alerts |> Enum.map(& &1["value"]["event"]["kind"]) |> Enum.sort() == [
             "geofence.entered",
             "geofence.exited",
             "trip.started"
           ]
  end

  test "nested position policies are closed and keep their complete identity", c do
    assert {:ok, %{"generation" => "4"}} = save(c, geofence(c.thing, "3"))
    assert {:ok, %{"value" => definition}} = policy(c, "yard")
    assert definition["kind"] == "geofence"
    assert is_binary(definition["policy_identity"])

    for request <- [
          put_in(geofence(c.thing, "4"), ["parameters", "boundary"], "sometimes"),
          put_in(geofence(c.thing, "4"), ["parameters", "shape", "extra"], true),
          put_in(geofence(c.thing, "4"), ["parameters", "shape"], %{
            "kind" => "polygon",
            "vertices" => "not-a-list"
          }),
          put_in(geofence(c.thing, "4"), ["parameters", "uncertainty"], "guess"),
          put_in(motion(c.thing, "4"), ["parameters", "event_time"], "device"),
          put_in(motion(c.thing, "4"), ["parameters", "sequence"], "latest"),
          put_in(motion(c.thing, "4"), ["parameters", "stationary_speed_m_s"], 2.0),
          put_in(motion(c.thing, "4"), ["parameters", "extra"], 1)
        ] do
      assert {:error, %{"code" => "invalid_request"}} = save(c, request)
    end

    changed = put_in(geofence(c.thing, "4"), ["parameters", "shape", "radius_m"], 200.0)
    assert {:ok, %{"generation" => "5"}} = save(c, changed)
    assert {:ok, %{"value" => revised}} = policy(c, "yard")
    refute revised["policy_identity"] == definition["policy_identity"]
  end

  test "polygon and alternate ordering policies round-trip without atomizing input", c do
    polygon =
      c.thing
      |> geofence("3")
      |> Map.put("id", "district")
      |> put_in(["parameters", "shape"], %{
        "kind" => "polygon",
        "vertices" => [
          %{"latitude" => 59.32, "longitude" => 18.05},
          %{"latitude" => 59.32, "longitude" => 18.09},
          %{"latitude" => 59.35, "longitude" => 18.07}
        ]
      })
      |> put_in(["parameters", "boundary"], "outside")
      |> put_in(["parameters", "uncertainty"], "require_bound")
      |> put_in(["parameters", "event_time"], "trusted_fix_or_receiver")
      |> put_in(["parameters", "sequence"], "optional")

    assert {:ok, %{"generation" => "4"}} = save(c, polygon)
    assert {:ok, %{"value" => %{"parameters" => parameters}}} = policy(c, "district")
    assert parameters == polygon["parameters"]

    alternate =
      c.thing
      |> motion("4")
      |> Map.put("id", "bounded-movement")
      |> put_in(["parameters", "event_time"], "trusted_fix_or_receiver")
      |> put_in(["parameters", "sequence"], "optional")
      |> put_in(["parameters", "uncertainty"], "require_bound")

    assert {:ok, %{"generation" => "5"}} = save(c, alternate)
    assert {:ok, %{"value" => %{"parameters" => parameters}}} = policy(c, "bounded-movement")
    assert parameters == alternate["parameters"]
  end

  test "missing, ambiguous and malformed position input never selects a source", c do
    assert {:ok, %{"generation" => "4"}} = save(c, geofence(c.thing, "3"))
    assert {:ok, %{"generation" => "5"}} = save(c, motion(c.thing, "4"))

    {:ok, access} = Service.authorize(c.service, c.admin, c.scope, "admin", c.now)

    {:ok, definitions} =
      RuleEvaluation.definitions(c.service, access, "admin", c.thing, "5", c.now)

    capture = observation(%{id: "selection-input"})
    {:ok, empty} = EvidenceBundle.new([capture], [])

    for definition <- definitions do
      assert {:ok, []} =
               RuleEvaluation.transitions(
                 c.service,
                 c.scope,
                 [definition],
                 capture,
                 empty,
                 c.now
               )
    end

    {:ok, first} = position_evidence("position-a", capture)
    {:ok, second} = position_evidence("position-b", capture)
    {:ok, ambiguous} = EvidenceBundle.new([capture], [first, second])

    for definition <- definitions do
      assert {:ok, []} =
               RuleEvaluation.transitions(
                 c.service,
                 c.scope,
                 [definition],
                 capture,
                 ambiguous,
                 c.now
               )
    end

    {:ok, invalid} =
      Evidence.new(%{
        id: "position-invalid",
        kind: :position,
        claim: %{},
        source_observation_ids: [capture.id],
        evidence_ids: [],
        profile: {"position", "1"},
        decoder: {"position", "1"},
        confidence: :exact,
        reasons: ["fixture"],
        association_id: nil
      })

    {:ok, malformed} = EvidenceBundle.new([capture], [invalid])

    for definition <- definitions do
      assert {:error, :conflict} =
               RuleEvaluation.transitions(
                 c.service,
                 c.scope,
                 [definition],
                 capture,
                 malformed,
                 c.now
               )
    end
  end

  defp materialize_position(c, id, observed_at, generation) do
    {:ok, imported} =
      Service.submit(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        import_request(%{id: id, observed_at: observed_at}, generation),
        observed_at
      )

    expected = Integer.to_string(String.to_integer(generation) + 1)

    {:ok, _} =
      Service.associate(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        %{
          "thing_id" => c.thing,
          "observation_id" => imported["data"]["observation_id"],
          "owner_confirmed" => true,
          "expected_generation" => expected
        },
        observed_at
      )

    Service.materialize(
      c.service,
      c.admin,
      c.scope,
      Identifier.uuid(),
      %{
        "thing_id" => c.thing,
        "expected_generation" => Integer.to_string(String.to_integer(expected) + 1)
      },
      observed_at
    )
  end

  defp save(c, request),
    do: Service.save_policy(c.service, c.admin, c.scope, Identifier.uuid(), request, c.now)

  defp rule(c, id), do: Service.get(c.service, c.reader, c.scope, "rules", id, c.now + 2_000)

  defp policy(c, id),
    do: Service.get(c.service, c.reader, c.scope, "policies", id, c.now + 2_000)

  defp geofence(thing, generation),
    do: %{
      "id" => "yard",
      "kind" => "geofence",
      "thing_id" => thing,
      "parameters" => %{
        "shape" => %{
          "kind" => "circle",
          "latitude" => 59.3293,
          "longitude" => 18.0686,
          "radius_m" => 100.0
        },
        "boundary" => "inside",
        "uncertainty" => "coordinate_only",
        "event_time" => "trusted_fix",
        "future_skew_ms" => 0,
        "late_window_ms" => 10_000,
        "sequence" => "none",
        "max_transition_gap_ms" => 10_000
      },
      "expected_generation" => generation
    }

  defp motion(thing, generation),
    do: %{
      "id" => "movement",
      "kind" => "motion",
      "thing_id" => thing,
      "parameters" => %{
        "event_time" => "trusted_fix",
        "future_skew_ms" => 0,
        "late_window_ms" => 10_000,
        "sequence" => "none",
        "moving_speed_m_s" => 1.0,
        "stationary_speed_m_s" => 0.1,
        "moving_distance_m" => 1.0,
        "stationary_distance_m" => 0.5,
        "max_plausible_speed_m_s" => 1_000.0,
        "max_gap_ms" => 10_000,
        "uncertainty" => "coordinate_only",
        "minimum_movement_ms" => 1_000,
        "minimum_stop_ms" => 1_000
      },
      "expected_generation" => generation
    }

  defp position_claim(observation) do
    longitude =
      case observation.id do
        "inside" -> 18.0686
        "outside-2" -> 18.0646
        _ -> 18.0706
      end

    %{
      "schema" => "wtr.position.v1",
      "latitude" => 59.3293,
      "longitude" => longitude,
      "altitude_m" => nil,
      "speed_m_s" => nil,
      "horizontal_accuracy_m" => 5.0,
      "accuracy_kind" => "bound",
      "source" => "gnss",
      "fix_at" => observation.observed_at,
      "device_at" => nil,
      "received_at" => observation.observed_at,
      "fix_clock" => "trusted",
      "device_clock" => "unknown",
      "availability" => "available",
      "quality" => "valid",
      "source_units" => %{
        "latitude" => "degree",
        "longitude" => "degree",
        "altitude" => nil,
        "speed" => nil,
        "accuracy" => "m",
        "fix_time" => "unix-ms",
        "device_time" => nil,
        "receiver_time" => "unix-ms"
      },
      "conversion_revision" => "fixture-position-rule-v1",
      "raw" => %{},
      "receiver_observation_id" => observation.id
    }
  end

  defp position_evidence(id, observation) do
    Evidence.new(%{
      id: id,
      kind: :position,
      claim: position_claim(observation),
      source_observation_ids: [observation.id],
      evidence_ids: [],
      profile: {"position", "1"},
      decoder: {"position", "1"},
      confidence: :exact,
      reasons: ["fixture"],
      association_id: nil
    })
  end
end
