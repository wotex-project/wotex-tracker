defmodule Wotex.Tracker.Service.PositionImportTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import Wotex.Tracker.Service.Fixtures

  alias Wotex.Tracker
  alias Wotex.Tracker.Decoders.RuuviRawV2
  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.{Codec, Identifier}

  setup do
    context = service()
    {:ok, profile} = RuuviRawV2.profile()
    revision = {"fixture.position", "1.0.0"}
    profile = %{profile | id: elem(revision, 0), version: elem(revision, 1), decoder: revision}
    {:ok, catalogue} = Tracker.catalogue([profile])

    callback = fn observation ->
      {:ok, decoded} = RuuviRawV2.decode(observation)
      {:ok, %{decoded | positions: [position_claim(observation)]}}
    end

    input = %{
      store: context.store,
      credentials: context.credentials,
      base_url: context.service.base_url,
      catalogue: catalogue,
      model: context.service.model,
      decoders: [{revision, callback}]
    }

    {:ok, configured} = Service.new(input)

    context
    |> Map.put(:service, configured)
    |> Map.put(:configuration, input)
    |> Map.put(:revision, revision)
  end

  test "configured position decoder commits a redacted public state and private lineage",
       context do
    assert {:ok, imported} =
             Service.submit(
               context.service,
               context.admin,
               context.scope,
               Identifier.uuid(),
               import_request(),
               context.now
             )

    observation_id = imported["data"]["observation_id"]

    assert {:ok, %{"value" => %{"positions" => [position]} = state}} =
             Service.get(
               context.service,
               context.reader,
               context.scope,
               "state",
               observation_id,
               context.now
             )

    assert position == %{
             "schema" => "wtr.position-public.v1",
             "latitude" => %{"type" => "number", "value" => 59.3293},
             "longitude" => %{"type" => "number", "value" => 18.0686},
             "altitude_m" => %{"type" => "null", "value" => nil},
             "speed_m_s" => %{"type" => "number", "value" => 0.0},
             "horizontal_accuracy_m" => %{"type" => "number", "value" => 5.0},
             "accuracy_kind" => "bound",
             "source" => "gnss",
             "fix_at" => %{"type" => "integer", "value" => context.now},
             "received_at" => %{"type" => "integer", "value" => context.now},
             "fix_clock" => "trusted",
             "availability" => "available",
             "quality" => "valid"
           }

    public = Codec.encode!(state)
    refute public =~ "private-position-source"
    refute public =~ "receiver_observation_id"
    refute public =~ "source_units"
    refute public =~ "conversion_revision"

    assert {:ok, evidence} =
             Service.raw_evidence(
               context.service,
               context.admin,
               context.scope,
               observation_id,
               context.now
             )

    assert evidence =~ "private-position-source"

    assert {:ok, enrolled} =
             Service.enroll(
               context.service,
               context.admin,
               context.scope,
               Identifier.uuid(),
               %{
                 "observation_id" => observation_id,
                 "title" => "Position fixture",
                 "owner_confirmed" => true,
                 "expected_generation" => "1"
               },
               context.now
             )

    thing_id = enrolled["data"]["thing_id"]

    assert {:ok, _} =
             Service.materialize(
               context.service,
               context.admin,
               context.scope,
               Identifier.uuid(),
               %{"thing_id" => thing_id, "expected_generation" => "2"},
               context.now
             )

    assert {:ok, %{"value" => %{"positions" => [^position]}}} =
             Service.get(
               context.service,
               context.reader,
               context.scope,
               "state",
               thing_id,
               context.now
             )
  end

  test "configured catalogue requires one exact callback per decoder revision", context do
    input = context.configuration
    callback = elem(hd(input.decoders), 1)

    for decoders <- [
          [],
          [{context.revision, callback}, {context.revision, callback}],
          [{{"other", "1.0.0"}, callback}],
          [{context.revision, :not_a_function}]
        ] do
      assert {:error, :invalid_configuration} = Service.new(%{input | decoders: decoders})
    end

    assert {:error, :invalid_configuration} =
             Service.new(%{input | catalogue: %{input.catalogue | identity: "forged"}})

    [profile] = input.catalogue.profiles
    {:ok, incompatible} = Tracker.catalogue([%{profile | model: {"other-model", "1.0.0"}}])

    assert {:error, :invalid_configuration} =
             Service.new(%{input | catalogue: incompatible})
  end

  defp position_claim(observation),
    do: %{
      "schema" => "wtr.position.v1",
      "latitude" => 59.3293,
      "longitude" => 18.0686,
      "altitude_m" => nil,
      "speed_m_s" => 0.0,
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
        "speed" => "m/s",
        "accuracy" => "m",
        "fix_time" => "unix-ms",
        "device_time" => nil,
        "receiver_time" => "unix-ms"
      },
      "conversion_revision" => "fixture-position-v1",
      "raw" => %{"source" => "private-position-source"},
      "receiver_observation_id" => observation.id
    }
end
