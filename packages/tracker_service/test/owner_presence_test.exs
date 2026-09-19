defmodule Wotex.Tracker.Service.OwnerPresenceTest do
  @moduledoc false

  use ExUnit.Case, async: true
  import Wotex.Tracker.Service.Fixtures
  alias Wotex.Tracker.{Evidence, EvidenceBundle, Observation, PolicyFact}
  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.{Identifier, OwnerPresence, Store}

  setup do
    c = service()
    {thing, _td} = materialized(c)
    Map.put(c, :thing, thing)
  end

  test "a closed owner-presence fact is admitted without exposing private evidence", c do
    {:ok, %{"stream_cursor" => stream}} =
      Service.list(c.service, c.reader, c.scope, "things", %{}, c.now)

    fact = fact(c.thing, "present", "true", c.now)
    request = request(c.thing, fact, "3")

    assert {:error, %{"code" => "forbidden", "outcome" => "not_committed"}} =
             admit(c, c.reader, Identifier.uuid(), request, c.now + 1)

    for invalid <- [
          %{},
          Map.put(request, "extra", true),
          %{request | "thing_id" => "thing"},
          %{request | "expected_generation" => "03"},
          put_in(request, ["fact", "predicate"], "owner.absent"),
          request(c.thing, fact("urn:uuid:" <> Identifier.uuid(), "other", "true", c.now), "3")
        ] do
      assert {:error, %{"code" => "invalid_request"}} =
               admit(c, c.admin, Identifier.uuid(), invalid, c.now + 1)
    end

    operation = Identifier.uuid()

    assert {:ok,
            %{
              "generation" => "4",
              "outcome" => "committed",
              "data" => data
            } = receipt} = admit(c, c.admin, operation, request, c.now + 1)

    assert data == %{"thing_id" => c.thing, "status" => "present", "observed_at" => c.now}
    assert {:ok, ^receipt} = admit(c, c.admin, operation, request, c.now + 2)

    assert {:ok, %{"generation" => "4", "id" => thing, "value" => present}} =
             Service.get(c.service, c.reader, c.scope, "owner_presence", c.thing, c.now + 2)

    assert thing == c.thing

    assert present == %{
             "schema" => "wtr.owner-presence.v1",
             "thing_id" => c.thing,
             "status" => "present",
             "revision" => "owner-presence-4",
             "observed_at" => c.now,
             "admitted_at" => c.now + 1,
             "admitted_by" => present["admitted_by"]
           }

    assert String.starts_with?(present["admitted_by"], "wtr1_")

    for private <- ["presence-evidence", "presence-observation", "owner.present"] do
      refute inspect(present) =~ private
    end

    assert {:ok, %{"items" => [%{"value" => ^present}]}} =
             Service.list(c.service, c.reader, c.scope, "owner_presence", %{}, c.now + 2)

    assert {:ok, %{"items" => [%{"value" => ^present}], "cursor" => cursor}} =
             Service.list(
               c.service,
               c.reader,
               c.scope,
               "owner_presence",
               %{"limit" => 1},
               c.now + 2
             )

    assert is_binary(cursor)

    assert {:ok, %{"items" => [], "cursor" => nil, "generation" => "4"}} =
             Service.list(
               c.service,
               c.reader,
               c.scope,
               "owner_presence",
               %{"limit" => 1, "cursor" => cursor},
               c.now + 2
             )

    assert {:ok, %{"items" => [%{"value" => ^present, "deleted" => false}]}} =
             Service.history(
               c.service,
               c.reader,
               c.scope,
               "owner_presence",
               c.thing,
               %{},
               c.now + 2
             )

    assert {:ok, %{"value" => stored}} =
             Store.fetch(c.store, %{
               scope: c.scope,
               kind: "owner_presence",
               id: c.thing,
               generation: nil
             })

    assert {:ok, restored} = OwnerPresence.restore_fact(c.thing, stored)
    assert restored.predicate == "owner.present"
    assert restored.status == "true"
    assert restored.evidence.association_id == c.thing

    assert {:ok, %{"items" => [%{"event" => event}]}} =
             Service.events(c.service, c.reader, c.scope, stream, c.now + 2)

    assert event == %{
             "type" => "owner_presence.changed",
             "data" => %{
               "thing_id" => c.thing,
               "status" => "present",
               "observed_at" => c.now
             }
           }
  end

  test "presence observations advance strictly and disappear from current views on unenrollment",
       c do
    first = fact(c.thing, "present", "true", c.now)

    assert {:ok, %{"generation" => "4"}} =
             admit(c, c.admin, Identifier.uuid(), request(c.thing, first, "3"), c.now)

    for rejected <- [
          fact(c.thing, "older", "false", c.now - 1),
          fact(c.thing, "same-time", "false", c.now)
        ] do
      assert {:error, %{"code" => "conflict"}} =
               admit(c, c.admin, Identifier.uuid(), request(c.thing, rejected, "4"), c.now + 1)
    end

    later = fact(c.thing, "absent", "false", c.now + 1)

    assert {:ok, %{"generation" => "5"}} =
             admit(c, c.admin, Identifier.uuid(), request(c.thing, later, "4"), c.now + 2)

    {reopened, _directory} = store(directory: c.directory, credentials: c.credentials)
    service = %{c.service | store: reopened}

    assert {:ok, %{"value" => %{"status" => "absent", "observed_at" => observed}}} =
             Service.get(service, c.reader, c.scope, "owner_presence", c.thing, c.now + 3)

    assert observed == c.now + 1

    assert {:ok, %{"generation" => "6"}} =
             Service.unenroll(
               service,
               c.admin,
               c.scope,
               Identifier.uuid(),
               %{"thing_id" => c.thing, "expected_generation" => "5"},
               c.now + 4
             )

    assert {:error, %{"code" => "not_found"}} =
             Service.get(service, c.reader, c.scope, "owner_presence", c.thing, c.now + 4)

    assert {:ok, %{"items" => versions}} =
             Service.history(
               service,
               c.reader,
               c.scope,
               "owner_presence",
               c.thing,
               %{},
               c.now + 4
             )

    assert Enum.map(versions, & &1["deleted"]) == [false, false, true]
  end

  test "a corrupt private fact fails its public projection closed", c do
    admitted = fact(c.thing, "present", "true", c.now)

    assert {:ok, %{"generation" => "4"}} =
             admit(c, c.admin, Identifier.uuid(), request(c.thing, admitted, "3"), c.now)

    assert {:ok, %{"value" => stored}} =
             Store.fetch(c.store, %{
               scope: c.scope,
               kind: "owner_presence",
               id: c.thing,
               generation: nil
             })

    changed = put_in(stored, ["fact", "predicate"], "owner.absent")
    assert {:error, :storage_unavailable} = OwnerPresence.project(c.thing, changed)
    assert {:error, :storage_unavailable} = OwnerPresence.project("other", stored)
  end

  defp admit(c, token, operation, request, now),
    do: Service.admit_owner_presence(c.service, token, c.scope, operation, request, now)

  defp request(thing, fact, generation),
    do: %{"thing_id" => thing, "fact" => fact, "expected_generation" => generation}

  defp fact(thing, id, status, observed_at) do
    observation_id = "presence-observation-" <> id
    evidence_id = "presence-evidence-" <> id

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
end
