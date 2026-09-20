defmodule Wotex.Tracker.Service.ATC700ContractTest do
  use ExUnit.Case, async: true

  import Wotex.Tracker.Service.Fixtures

  alias Wotex.Tracker.Observation
  alias Wotex.Tracker.Protocols.Teltonika.ATC700
  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.{Codec, Identifier}

  setup do
    context = service()

    {:ok, service} =
      Service.new(%{
        store: context.store,
        credentials: context.credentials,
        base_url: "http://127.0.0.1:45678",
        contract: :teltonika_atc700_codec8e,
        cellular_ingress: :configured
      })

    {:ok, fixture} =
      Wotex.JSON.decode(File.read!("../../test/fixtures/teltonika/atc700.json"))

    [vector] = fixture["vectors"]
    frame = Base.decode16!(vector["hex"])
    <<_::binary-size(9), record_count, _::binary>> = frame

    {:ok, observation} =
      Observation.new(%{
        id: "atc700-service-frame",
        observed_at: 1_700_000_000_500,
        ingress: "cellular",
        source: %{"adapter" => "teltonika-tcp", "device" => "compact-asset"},
        addressing: %{"identity_digest" => String.duplicate("c", 64)},
        payload: {:bytes, frame},
        radio: %{},
        transport: %{"codec" => 0x8E, "record_count" => record_count},
        provenance: %{
          "protocol" => "teltonika-codec8-extended",
          "configured_profile" => ATC700.configured_profile(),
          "identity_assurance" => "configured-routing-identifier"
        }
      })

    Map.merge(context, %{service: service, observation: observation})
  end

  test "the packaged contract persists ordered ATC700 records and battery level", context do
    {:ok, document} = Observation.to_map(context.observation)

    assert {:ok, %{"data" => %{"observation_id" => id}}} =
             Service.submit(
               context.service,
               context.admin,
               context.scope,
               Identifier.uuid(),
               %{"observation" => document, "expected_generation" => "0"},
               context.now
             )

    assert {:ok, %{"value" => state}} =
             Service.get(
               context.service,
               context.reader,
               context.scope,
               "state",
               id,
               context.now
             )

    assert [moving, stopped] = state["records"]

    assert Enum.map(moving["measurements"], &{&1["kind"], &1["value"]["value"]}) == [
             {"motion", true},
             {"batteryVoltage", 3.6},
             {"batteryLevel", 72}
           ]

    assert Enum.map(stopped["measurements"], & &1["kind"]) == ~w(motion batteryVoltage)
    assert state["measurements"] == stopped["measurements"]

    assert {:ok, raw} =
             Service.raw_evidence(
               context.service,
               context.admin,
               context.scope,
               id,
               context.now
             )

    claims = Codec.decode!(raw)
    assert length(claims) == 12
    assert Enum.count(claims, &(&1["kind"] == "transport")) == 2
    assert Enum.count(claims, &(&1["kind"] == "capability")) == 4
  end
end
