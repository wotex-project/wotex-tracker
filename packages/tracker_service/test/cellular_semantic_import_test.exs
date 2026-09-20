defmodule Wotex.Tracker.Service.CellularSemanticImportTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import Wotex.Tracker.Service.Fixtures

  alias Wotex.Tracker.{Catalogue, Model}
  alias Wotex.Tracker.Protocols.Teltonika.{Codec8Extended, TAT140, TAT140Import, TCPSession}
  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.Cellular.Ingress
  alias Wotex.Tracker.Service.{Codec, Identifier}

  @imei "123456789012345"
  @identity_key :binary.copy(<<9>>, 32)

  setup do
    context = cellular_service()
    ingress = start_ingress(context)
    %{context: context, ingress: ingress, packet: packet()}
  end

  test "one durable frame retains every semantic record and materialises its Thing", context do
    assert {:ok, session} = Ingress.login(context.ingress, @imei)

    assert {:ok, %{disposition: :accepted, record_count: 2}} =
             Ingress.submit(context.ingress, session, context.packet)

    assert {:ok, %{"generation" => "1", "items" => [%{"id" => observation_id}]}} =
             Service.list(
               context.context.service,
               context.context.admin,
               context.context.scope,
               "observations",
               %{"limit" => 10},
               context.context.now
             )

    assert {:ok, %{"generation" => "1", "value" => state}} =
             Service.get(
               context.context.service,
               context.context.reader,
               context.context.scope,
               "state",
               observation_id,
               context.context.now
             )

    assert [moving, stopped] = state["records"]
    assert moving["schema"] == "wtr.cellular-record-public.v1"
    assert moving["index"] == %{"type" => "integer", "value" => 0}
    assert moving["timestamp_ms"] == %{"type" => "integer", "value" => 1_700_000_000_000}
    assert moving["priority"] == "high"

    assert Enum.map(moving["measurements"], &{&1["kind"], &1["value"]["value"]}) == [
             {"motion", true},
             {"batteryVoltage", 3.6}
           ]

    assert [position] = moving["positions"]
    assert position["latitude"]["value"] == 59.0
    assert position["longitude"]["value"] == 18.0

    assert stopped["index"] == %{"type" => "integer", "value" => 1}
    assert stopped["positions"] == []
    assert state["measurements"] == stopped["measurements"]
    assert state["positions"] == []

    assert {:ok, private} =
             Service.raw_evidence(
               context.context.service,
               context.context.admin,
               context.context.scope,
               observation_id,
               context.context.now
             )

    claims = Codec.decode!(private)
    assert length(claims) == 10

    records =
      claims
      |> Enum.filter(&(&1["kind"] == "transport"))
      |> Enum.sort_by(& &1["claim"]["index"])

    assert Enum.map(records, & &1["claim"]["index"]) == [0, 1]
    assert Enum.map(hd(records)["claim"]["io_elements"], & &1["id"]) == [240, 113, 67, 999]

    assert {:ok, enrolled} =
             Service.enroll(
               context.context.service,
               context.context.admin,
               context.context.scope,
               Identifier.uuid(),
               %{
                 "observation_id" => observation_id,
                 "title" => "Cellular asset",
                 "owner_confirmed" => true,
                 "expected_generation" => "1"
               },
               context.context.now
             )

    thing_id = enrolled["data"]["thing_id"]

    assert {:ok, %{"generation" => "3"}} =
             Service.materialize(
               context.context.service,
               context.context.admin,
               context.context.scope,
               Identifier.uuid(),
               %{"thing_id" => thing_id, "expected_generation" => "2"},
               context.context.now
             )

    assert {:ok, %{"value" => td}} =
             Service.get(
               context.context.service,
               context.context.reader,
               context.context.scope,
               "things",
               thing_id,
               context.context.now
             )

    assert td["version"]["model"] == "1.0.0"
    assert Map.keys(td["properties"]) |> Enum.sort() == ~w(batteryVoltage motion position)

    assert {:ok, %{"value" => thing_state}} =
             Service.get(
               context.context.service,
               context.context.reader,
               context.context.scope,
               "state",
               thing_id,
               context.context.now
             )

    assert thing_state["records"] == state["records"]
  end

  test "record decoder configuration and callback results stay explicit", context do
    input = context.context.configuration
    revision = TAT140.revision()

    for decoders <- [
          [{revision, {:records, fn _observation -> :invalid end}}],
          [{revision, {:unknown, &TAT140Import.run/2}}],
          [{revision, {:records, :not_a_function}}]
        ] do
      assert {:error, :invalid_configuration} = Service.new(%{input | decoders: decoders})
    end

    forged = fn _observation, _catalogue -> {:ok, :forged} end
    {:ok, service} = Service.new(%{input | decoders: [{revision, {:records, forged}}]})
    ingress = start_ingress(%{context.context | service: service})
    assert {:ok, session} = Ingress.login(ingress, @imei)
    assert {:ok, %{disposition: :rejected}} = Ingress.submit(ingress, session, context.packet)
  end

  test "an unknown post-commit response retains the complete record batch for retry" do
    context =
      cellular_service(fault: fn phase -> if phase == :after_commit, do: :abort, else: :ok end)

    ingress = start_ingress(context)
    assert {:ok, session} = Ingress.login(ingress, @imei)

    assert {:ok, %{disposition: :unknown}} = Ingress.submit(ingress, session, packet())

    assert {:ok, %{disposition: :duplicate}} = Ingress.submit(ingress, session, packet())

    assert {:ok, %{"items" => [%{"id" => id}]}} =
             Service.list(
               context.service,
               context.admin,
               context.scope,
               "observations",
               %{"limit" => 10},
               context.now
             )

    assert {:ok, %{"value" => %{"records" => [_, _]}}} =
             Service.get(context.service, context.reader, context.scope, "state", id, context.now)
  end

  defp cellular_service(options \\ []) do
    context = service(options)
    {:ok, profile} = TAT140.profile()
    {:ok, catalogue} = Catalogue.new([profile])

    path =
      Application.app_dir(
        :wotex_tracker,
        "priv/thing_models/cellular-asset-tracker-1.0.0.tm.json"
      )

    {:ok, document} = path |> File.read!() |> Wotex.JSON.decode()
    {:ok, model} = Model.new(document, profile.model)

    input = %{
      store: context.store,
      credentials: context.credentials,
      base_url: context.service.base_url,
      catalogue: catalogue,
      model: model,
      decoders: [{TAT140.revision(), {:records, &TAT140Import.run/2}}]
    }

    {:ok, configured} = Service.new(input)
    context |> Map.put(:service, configured) |> Map.put(:configuration, input)
  end

  defp start_ingress(context) do
    {:ok, identity_digest} = TCPSession.identity_digest(@imei, @identity_key)

    options = [
      service: context.service,
      identity_key: @identity_key,
      devices: [
        %{
          identity_digest: identity_digest,
          token: context.admin,
          scope: context.scope,
          id: "configured-tracker",
          profile: TAT140.configured_profile()
        }
      ],
      clock: fn -> context.now end
    ]

    start_supervised!(
      Supervisor.child_spec({Ingress, options}, id: make_ref(), restart: :temporary)
    )
  end

  defp packet do
    {:ok, fixture} =
      Wotex.JSON.decode(File.read!("../../test/fixtures/teltonika/tat140.json"))

    [vector] = fixture["vectors"]
    {:ok, packet} = vector["hex"] |> Base.decode16!() |> Codec8Extended.decode_frame()
    packet
  end
end
