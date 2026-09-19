defmodule Wotex.Tracker.Service.SuspiciousOrchestrationTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import Wotex.Tracker.Service.Fixtures

  alias Exqlite.Sqlite3
  alias Wotex.Tracker
  alias Wotex.Tracker.Decoders.RuuviRawV2
  alias Wotex.Tracker.{Evidence, EvidenceBundle, Observation, PolicyFact}
  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.{Identifier, Store}

  setup do
    context = service()
    {:ok, profile} = RuuviRawV2.profile()
    revision = {"fixture.suspicious-orchestration", "1.0.0"}
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

  test "a motion transition stages one reviewed suspicious-movement alert", c do
    assert {:ok, %{"generation" => "4"}} = save(c, motion(c.thing, "3"), c.now)
    assert {:ok, %{"generation" => "5"}} = save(c, suspicious(c.thing, "4"), c.now)
    assert {:ok, %{"generation" => "6"}} = arm(c, "armed", "5", c.now)
    assert {:ok, %{"generation" => "7"}} = presence(c, "false", "6", c.now, c.now)

    assert {:ok, %{"generation" => "10"}} =
             materialize_position(c, "moving-1", c.now + 1_000, "7")

    assert {:ok, %{"generation" => "13"}} =
             materialize_position(c, "moving-2", c.now + 2_000, "10")

    [alert] = suspicious_alerts(c, c.now + 2_000)
    value = alert["value"]
    assert value["thing_id"] == c.thing
    assert value["generation"] == "13"
    assert value["rule"] == %{"kind" => "suspicious_movement", "id" => "suspicious-motion"}
    assert value["mode"] == "live"
    assert value["physical_action_dispatch"] == "separate_authorization_required"
    assert value["event"]["active_trip_id"]

    for private <-
          ~w(motion_state_identity armed_fact_identity owner_presence_fact_identity movement_position_evidence_id armed_evidence_id owner_presence_evidence_id) do
      refute Map.has_key?(value["event"], private)
    end

    assert {:ok, intent} = Store.rule_event(c.store, c.scope, value["event_id"])
    assert intent["generation"] == "13"
    assert intent["event"]["armed_evidence_id"]
    assert intent["event"]["owner_presence_evidence_id"]
  end

  test "arming is the triggering input only after motion and explicit absence", c do
    assert {:ok, %{"generation" => "4"}} = save(c, motion(c.thing, "3"), c.now)
    assert {:ok, %{"generation" => "5"}} = save(c, suspicious(c.thing, "4"), c.now)
    assert {:ok, %{"generation" => "11"}} = become_moving(c, "5")

    assert {:ok, %{"generation" => "12"}} =
             presence(c, "false", "11", c.now + 2_000, c.now + 2_000)

    assert suspicious_alerts(c, c.now + 2_000) == []
    assert {:ok, %{"generation" => "13"}} = arm(c, "disarmed", "12", c.now + 3_000)
    assert suspicious_alerts(c, c.now + 3_000) == []
    assert {:ok, %{"generation" => "14"}} = arm(c, "armed", "13", c.now + 4_000)
    assert length(suspicious_alerts(c, c.now + 4_000)) == 1
  end

  test "a newer explicit absence triggers after present evidence kept the rule clear", c do
    assert {:ok, %{"generation" => "4"}} = save(c, motion(c.thing, "3"), c.now)
    assert {:ok, %{"generation" => "5"}} = save(c, suspicious(c.thing, "4"), c.now)
    assert {:ok, %{"generation" => "11"}} = become_moving(c, "5")
    assert {:ok, %{"generation" => "12"}} = arm(c, "armed", "11", c.now + 2_000)

    assert {:ok, %{"generation" => "13"}} =
             presence(c, "true", "12", c.now + 2_000, c.now + 3_000)

    assert suspicious_alerts(c, c.now + 3_000) == []

    assert {:ok, %{"generation" => "14"}} =
             presence(c, "false", "13", c.now + 4_000, c.now + 4_000)

    assert length(suspicious_alerts(c, c.now + 4_000)) == 1
  end

  test "saving the event-only definition evaluates already committed exact inputs", c do
    assert {:ok, %{"generation" => "4"}} = save(c, motion(c.thing, "3"), c.now)
    assert {:ok, %{"generation" => "10"}} = become_moving(c, "4")
    assert {:ok, %{"generation" => "11"}} = arm(c, "armed", "10", c.now + 2_000)

    assert {:ok, %{"generation" => "12"}} =
             presence(c, "false", "11", c.now + 2_000, c.now + 2_000)

    assert suspicious_alerts(c, c.now + 2_000) == []

    assert {:ok, %{"generation" => "13"}} =
             save(c, suspicious(c.thing, "12"), c.now + 3_000)

    [alert] = suspicious_alerts(c, c.now + 3_000)
    assert alert["generation"] == "13"
    assert alert["value"]["generation"] == "13"
  end

  test "unknown presence triggers only when the exact policy opts into absence", c do
    assert {:ok, %{"generation" => "4"}} = save(c, motion(c.thing, "3"), c.now)
    assert {:ok, %{"generation" => "10"}} = become_moving(c, "4")
    assert {:ok, %{"generation" => "11"}} = arm(c, "armed", "10", c.now + 2_000)

    assert {:ok, %{"generation" => "12"}} =
             presence(c, "unknown", "11", c.now + 2_000, c.now + 2_000)

    assert {:ok, %{"generation" => "13"}} =
             save(c, suspicious(c.thing, "12"), c.now + 3_000)

    assert suspicious_alerts(c, c.now + 3_000) == []

    opted_in =
      c.thing
      |> suspicious("13")
      |> put_in(["parameters", "owner_unknown_as_absent"], true)

    assert {:ok, %{"generation" => "14"}} = save(c, opted_in, c.now + 4_000)
    [alert] = suspicious_alerts(c, c.now + 4_000)
    assert alert["value"]["event"]["owner_unknown_interpretation"] == "unknown_treated_as_absent"
  end

  test "a changed motion definition disables an older exact suspicious binding", c do
    assert {:ok, %{"generation" => "4"}} = save(c, motion(c.thing, "3"), c.now)
    assert {:ok, %{"generation" => "5"}} = save(c, suspicious(c.thing, "4"), c.now)
    assert {:ok, %{"generation" => "11"}} = become_moving(c, "5")
    assert {:ok, %{"generation" => "12"}} = arm(c, "armed", "11", c.now + 2_000)

    assert {:ok, %{"generation" => "13"}} =
             presence(c, "true", "12", c.now + 2_000, c.now + 3_000)

    revised = put_in(motion(c.thing, "13"), ["parameters", "moving_speed_m_s"], 2.0)
    assert {:ok, %{"generation" => "14"}} = save(c, revised, c.now + 4_000)

    assert {:ok, %{"generation" => "15"}} =
             presence(c, "false", "14", c.now + 5_000, c.now + 5_000)

    assert suspicious_alerts(c, c.now + 5_000) == []
  end

  test "deleting the referenced motion definition removes the live binding", c do
    assert {:ok, %{"generation" => "4"}} = save(c, motion(c.thing, "3"), c.now)
    assert {:ok, %{"generation" => "5"}} = save(c, suspicious(c.thing, "4"), c.now)

    assert {:ok, %{"generation" => "6"}} =
             Service.delete_policy(
               c.service,
               c.admin,
               c.scope,
               Identifier.uuid(),
               %{"id" => "movement", "expected_generation" => "5"},
               c.now
             )

    assert {:ok, %{"generation" => "7"}} = arm(c, "armed", "6", c.now + 1)
    assert suspicious_alerts(c, c.now + 1) == []
  end

  test "corrupt motion state and fact inputs fail triggering mutations closed", c do
    assert {:ok, %{"generation" => "4"}} = save(c, motion(c.thing, "3"), c.now)
    assert {:ok, %{"generation" => "5"}} = save(c, suspicious(c.thing, "4"), c.now)
    damage(c, "UPDATE rule_states SET document='{}' WHERE kind='motion'")

    assert {:error, %{"code" => "storage_unavailable", "outcome" => "not_committed"}} =
             arm(c, "armed", "5", c.now + 1)

    assert {:error, %{"code" => "not_found"}} =
             Service.get(c.service, c.reader, c.scope, "arming", c.thing, c.now + 1)

    damage(
      c,
      "UPDATE rule_states SET document=(SELECT document FROM records " <>
        "WHERE kind='rules' AND id='motion:movement' ORDER BY generation DESC LIMIT 1) " <>
        "WHERE kind='motion'"
    )

    assert {:ok, %{"generation" => "6"}} = arm(c, "armed", "5", c.now + 1)

    damage(
      c,
      "UPDATE records SET document=json_set(document,'$.fact.predicate','asset.other') " <>
        "WHERE kind='arming'"
    )

    assert {:error, %{"code" => "storage_unavailable", "outcome" => "not_committed"}} =
             presence(c, "false", "6", c.now + 2, c.now + 2)
  end

  test "an injected commit failure rolls back the triggering fact and staged alert", c do
    assert {:ok, %{"generation" => "4"}} = save(c, motion(c.thing, "3"), c.now)
    assert {:ok, %{"generation" => "5"}} = save(c, suspicious(c.thing, "4"), c.now)
    assert {:ok, %{"generation" => "11"}} = become_moving(c, "5")
    assert {:ok, %{"generation" => "12"}} = arm(c, "armed", "11", c.now + 2_000)

    GenServer.stop(c.store.pid)

    {failed_store, _directory} =
      store(
        directory: c.directory,
        credentials: c.credentials,
        fault: fn phase -> if phase == :before_commit, do: :abort, else: :ok end
      )

    failed = %{c | store: failed_store, service: %{c.service | store: failed_store}}

    assert {:error, %{"code" => "storage_unavailable", "outcome" => "not_committed"}} =
             presence(failed, "false", "12", c.now + 3_000, c.now + 3_000)

    assert {:ok, %{"generation" => "12", "items" => alerts}} =
             Service.list(
               failed.service,
               failed.reader,
               failed.scope,
               "alerts",
               %{},
               c.now + 3_000
             )

    refute Enum.any?(alerts, &(get_in(&1, ["value", "event", "kind"]) == "suspicious_movement"))

    assert {:error, %{"code" => "not_found"}} =
             Service.get(
               failed.service,
               failed.reader,
               failed.scope,
               "owner_presence",
               failed.thing,
               c.now + 3_000
             )
  end

  defp become_moving(c, generation) do
    first_at = c.now + 1_000
    second_at = c.now + 2_000

    with {:ok, %{"generation" => first_generation}} <-
           materialize_position(c, "moving-1", first_at, generation),
         {:ok, %{"generation" => second_generation} = receipt} <-
           materialize_position(c, "moving-2", second_at, first_generation),
         true <- String.to_integer(second_generation) == String.to_integer(generation) + 6 do
      {:ok, receipt}
    else
      false -> {:error, :wrong_generation}
      error -> error
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

    associated_generation = next_generation(generation)

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
          "expected_generation" => associated_generation
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
        "expected_generation" => next_generation(associated_generation)
      },
      observed_at
    )
  end

  defp save(c, request, now),
    do: Service.save_policy(c.service, c.admin, c.scope, Identifier.uuid(), request, now)

  defp arm(c, status, generation, now),
    do:
      Service.set_arming(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        %{"thing_id" => c.thing, "status" => status, "expected_generation" => generation},
        now
      )

  defp presence(c, status, generation, observed_at, now),
    do:
      Service.admit_owner_presence(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        %{
          "thing_id" => c.thing,
          "fact" => fact(c.thing, status, observed_at),
          "expected_generation" => generation
        },
        now
      )

  defp suspicious_alerts(c, now) do
    {:ok, %{"items" => alerts}} =
      Service.list(c.service, c.reader, c.scope, "alerts", %{}, now)

    Enum.filter(alerts, &(get_in(&1, ["value", "event", "kind"]) == "suspicious_movement"))
  end

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

  defp suspicious(thing, generation),
    do: %{
      "id" => "suspicious-motion",
      "kind" => "suspicious_movement",
      "thing_id" => thing,
      "parameters" => %{
        "motion_rule_id" => "movement",
        "maximum_fact_age_ms" => 60_000,
        "future_skew_ms" => 1_000,
        "owner_unknown_as_absent" => false
      },
      "expected_generation" => generation
    }

  defp position_claim(observation) do
    longitude =
      case observation.id do
        "moving-1" -> 18.0716
        "moving-2" -> 18.0726
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
      "conversion_revision" => "fixture-suspicious-orchestration-v1",
      "raw" => %{},
      "receiver_observation_id" => observation.id
    }
  end

  defp fact(thing, status, observed_at) do
    suffix = status <> "-" <> Integer.to_string(observed_at)
    observation_id = "presence-observation-" <> suffix
    evidence_id = "presence-evidence-" <> suffix

    {:ok, observation} =
      Observation.new(%{
        id: observation_id,
        observed_at: observed_at,
        ingress: "imported",
        source: %{"kind" => "qualified-owner-presence"},
        addressing: %{"thing_id" => thing},
        payload: {:json, %{"predicate" => "owner.present", "status" => status}},
        radio: %{},
        transport: %{},
        provenance: %{"kind" => "test-presence-source"}
      })

    {:ok, evidence} =
      Evidence.new(%{
        id: evidence_id,
        kind: :identity,
        claim: %{
          "schema" => "wtr.policy-fact.v1",
          "predicate" => "owner.present",
          "status" => status,
          "policy_revision" => "presence-source-v1",
          "reason" => "qualified_observation"
        },
        source_observation_ids: [observation_id],
        evidence_ids: [],
        profile: {"test-presence", "1"},
        decoder: {"test-presence", "1"},
        confidence: :exact,
        reasons: ["qualified_observation"],
        association_id: thing
      })

    {:ok, bundle} = EvidenceBundle.new([observation], [evidence])
    {:ok, admitted} = PolicyFact.new(evidence_id, bundle)
    {:ok, document} = PolicyFact.to_map(admitted)
    document
  end

  defp next_generation(generation),
    do: generation |> String.to_integer() |> Kernel.+(1) |> Integer.to_string()

  defp damage(c, statement) do
    {:ok, db} = Sqlite3.open(Path.join(c.directory, "tracker.db"))

    try do
      {:ok, prepared} = Sqlite3.prepare(db, statement)
      {:ok, []} = Sqlite3.fetch_all(db, prepared)
      :ok = Sqlite3.release(db, prepared)
    after
      Sqlite3.close(db)
    end
  end
end
