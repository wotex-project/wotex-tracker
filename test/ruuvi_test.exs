defmodule Wotex.Tracker.RuuviTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Bitwise, only: [bsl: 2, bor: 2]

  alias Wotex.Tracker.{
    Capability,
    Catalogue,
    Decoder,
    Error,
    EvidenceBundle,
    Fixtures,
    Measurement,
    Resolution
  }

  alias Wotex.Tracker.Decoders.RuuviRawV2

  setup do
    {:ok, fixture} = Wotex.JSON.decode(File.read!("test/fixtures/ruuvi/raw_v2.json"))
    {:ok, profile} = RuuviRawV2.profile()
    {:ok, catalogue} = Catalogue.new([profile])
    %{fixture: fixture, catalogue: catalogue}
  end

  test "independent source vectors preserve expected types, units, raw and quality", %{
    fixture: fixture,
    catalogue: catalogue
  } do
    for vector <- fixture["vectors"] do
      bytes = Base.decode16!(vector["hex"])
      observation = capture(bytes)
      assert {:ok, result} = RuuviRawV2.decode(observation)
      assert result.identity["protocol_mac"] === vector["expected_mac"]
      measurements = Map.new(result.measurements, &{&1.kind, &1})
      assert map_size(measurements) == 10

      for {kind, expected} <- vector["expected"] do
        measurement = measurements[kind]
        assert measurement.value === expected
        assert measurement.unit === fixture["units"][kind]

        assert measurement.availability ==
                 if(is_nil(expected), do: :unavailable, else: :available)

        if kind in vector["suspect"], do: assert(measurement.quality == :suspect)
      end

      assert {:ok, resolution} = Resolution.resolve(observation, catalogue)

      assert {:ok, decoded} =
               Decoder.run(
                 observation,
                 resolution,
                 catalogue,
                 {RuuviRawV2.revision(), &RuuviRawV2.decode/1}
               )

      assert length(decoded.capabilities) == 10
      assert map_size(decoded.bundle.evidence) == 21
      assert decoded.bundle.observations[observation.id] === observation
      assert {:ok, _} = EvidenceBundle.validate(decoded.bundle)

      for capability <- decoded.capabilities do
        assert {:ok, projected} = Capability.to_map(capability, decoded.bundle)
        assert projected["operations"] == ["read"]
        refute projected["id"] in ["movement", "batteryPercentage", "motion"]
      end
    end
  end

  test "company bytes are separate and little endian; payload fields are big endian", %{
    fixture: fixture,
    catalogue: catalogue
  } do
    bytes = Base.decode16!(hd(fixture["vectors"])["hex"])

    assert {:ok, %{payload: {:bytes, ^bytes}, transport: %{"manufacturer_id" => 1177}}} =
             RuuviRawV2.manufacturer_data(<<0x99, 0x04, bytes::binary>>)

    for value <- [
          <<0x04, 0x99, bytes::binary>>,
          bytes,
          <<>>,
          :bad,
          <<0x99, 0x04, bytes::binary, 0>>
        ],
        do: assert({:error, _} = RuuviRawV2.manufacturer_data(value))

    for transport <- [%{}, %{"manufacturer_id" => 0x9904}, %{"manufacturer_id" => 1177.0}] do
      observation = Fixtures.observation(%{payload: {:bytes, bytes}, transport: transport})
      assert {:ok, %{status: :unknown}} = Resolution.resolve(observation, catalogue)
    end
  end

  test "malformed length and unsupported versions fail without bit-match exceptions", %{
    fixture: fixture
  } do
    bytes = Base.decode16!(hd(fixture["vectors"])["hex"])

    for size <- 0..23 do
      assert {:error, %Error{code: :malformed_frame}} =
               RuuviRawV2.decode(capture(binary_part(bytes, 0, size)))
    end

    assert {:error, %Error{code: :malformed_frame}} =
             RuuviRawV2.decode(capture(<<bytes::binary, 0>>))

    <<5, rest::binary>> = bytes

    assert {:error, %Error{code: :unsupported_version}} =
             RuuviRawV2.decode(capture(<<6, rest::binary>>))

    assert {:error, _} = RuuviRawV2.decode(:forged)
    assert {:error, _} = RuuviRawV2.decode(Fixtures.observation(%{payload: {:json, %{}}}))
  end

  test "battery and TX missing sentinels are independent; zeros are available" do
    for {power, battery, tx} <- [
          {bor(bsl(2047, 5), 22), nil, 4},
          {bor(bsl(1000, 5), 31), 2.6, nil},
          {0, 1.6, -40}
        ] do
      {:ok, result} = RuuviRawV2.decode(capture(frame(0, 0, power, 0, 0)))
      values = Map.new(result.measurements, &{&1.kind, &1.value})
      assert values["batteryVoltage"] === battery
      assert values["txPower"] === tx
      assert values["temperature"] === 0.0
      assert values["humidity"] === 0.0
      assert values["movementCounter"] === 0
      assert values["measurementSequence"] === 0
    end

    {:ok, result} = RuuviRawV2.decode(capture(frame(-32_768, 40_001, 0, 254, 65_534)))
    measurements = Map.new(result.measurements, &{&1.kind, &1})
    assert measurements["temperature"].quality == :unavailable
    assert measurements["humidity"].quality == :suspect
    assert measurements["humidity"].value === 100.0025

    for {movement, sequence} <- [{254, 65_534}, {0, 0}, {255, 65_535}] do
      {:ok, result} = RuuviRawV2.decode(capture(frame(0, 0, 0, movement, sequence)))
      refute Enum.any?(result.measurements, &(&1.kind in ["motion", "movementEvent"]))
    end
  end

  test "callback never runs for unknown/ambiguous or mismatched revisions", %{
    catalogue: catalogue
  } do
    owner = self()

    callback = fn _ ->
      send(owner, :called)
      {:ok, %{measurements: [], identity: %{}}}
    end

    observation = capture(frame(0, 0, 0, 0, 0))
    {:ok, profile} = RuuviRawV2.profile()
    {:ok, ambiguous} = Catalogue.new([profile, %{profile | id: "other"}])

    for {observation, catalogue} <- [
          {Fixtures.observation(), catalogue},
          {observation, ambiguous}
        ] do
      {:ok, resolution} = Resolution.resolve(observation, catalogue)

      assert {:error, %Error{code: :unknown_resolution}} =
               Decoder.run(observation, resolution, catalogue, {RuuviRawV2.revision(), callback})

      refute_received :called
    end

    {:ok, resolution} = Resolution.resolve(observation, catalogue)

    for config <- [:bad, {RuuviRawV2.revision(), :module}, {{"ruuvi.rawv2", "2"}, callback}] do
      assert {:error, %Error{code: :revision_mismatch}} =
               Decoder.run(observation, resolution, catalogue, config)

      refute_received :called
    end

    assert {:error, _} =
             Decoder.run(
               observation,
               %{resolution | selected: nil},
               catalogue,
               {RuuviRawV2.revision(), callback}
             )

    refute_received :called
  end

  test "hostile callback outputs are bounded and typed; programming errors propagate", %{
    catalogue: catalogue
  } do
    observation = capture(frame(0, 0, 0, 0, 0))
    {:ok, resolution} = Resolution.resolve(observation, catalogue)
    {:ok, output} = RuuviRawV2.decode(observation)

    invalid = [
      :ok,
      {:ok, []},
      {:ok, %{measurements: [], identity: [], secret: "hidden"}},
      {:ok, %{measurements: [:bad], identity: %{}}},
      {:ok, %{output | measurements: [hd(output.measurements), hd(output.measurements)]}},
      {:ok, %{output | measurements: [hd(output.measurements) | :bad]}},
      {:error, :bad},
      {:error, %{__struct__: Error}},
      {:error, %Error{code: :secret, phase: :decode}}
    ]

    for returned <- invalid do
      assert {:error, %Error{code: :invalid_decoder_result}} =
               Decoder.run(
                 observation,
                 resolution,
                 catalogue,
                 {RuuviRawV2.revision(), fn _ -> returned end}
               )
    end

    error = Error.new(:unavailable, :decode)

    assert {:error, ^error} =
             Decoder.run(
               observation,
               resolution,
               catalogue,
               {RuuviRawV2.revision(), fn _ -> {:error, error} end}
             )

    assert {:error, _} =
             Decoder.run(
               observation,
               resolution,
               catalogue,
               {RuuviRawV2.revision(), &RuuviRawV2.decode/1},
               max_claims: 1
             )

    assert_raise RuntimeError, "programming defect", fn ->
      Decoder.run(
        observation,
        resolution,
        catalogue,
        {RuuviRawV2.revision(), fn _ -> raise "programming defect" end}
      )
    end
  end

  test "measurement and capability contracts reject invented support", %{catalogue: catalogue} do
    observation = capture(frame(0, 0, 0, 0, 0))
    {:ok, resolution} = Resolution.resolve(observation, catalogue)

    {:ok, result} =
      Decoder.run(
        observation,
        resolution,
        catalogue,
        {RuuviRawV2.revision(), &RuuviRawV2.decode/1}
      )

    sample = hd(result.measurements)

    for {key, value} <- [
          availability: :unavailable,
          quality: :unavailable,
          value: nil,
          value: "24.3",
          value: %{"pretend" => "measurement"},
          raw: {:bytes, <<0>>},
          kind: ""
        ] do
      assert {:error, _} = Measurement.validate(Map.put(sample, key, value))
    end

    assert {:error, _} = Measurement.new(%{})
    assert {:error, _} = Measurement.validate(:bad)
    assert {:error, _} = Measurement.to_map(:bad)

    {:ok, false_measurement} =
      Measurement.new(%{
        kind: "synthetic",
        value: false,
        raw: false,
        unit: "1",
        availability: :available,
        quality: :valid,
        reason: "synthetic"
      })

    assert {:ok, %{"value" => false}} = Measurement.to_map(false_measurement)
    capability = hd(result.capabilities)

    for {key, value} <- [
          operations: [:write],
          kind: :action,
          evidence_ids: [],
          evidence_ids: ["missing"],
          id: "invented",
          unit: "wrong"
        ] do
      assert {:error, _} = Capability.validate(Map.put(capability, key, value), result.bundle)
    end

    {:ok, measurement_claim} =
      Enum.find(result.bundle.evidence, fn {_id, claim} -> claim.kind == :measurement end)
      |> then(fn {_id, value} -> {:ok, value} end)

    assert {:error, _} =
             Capability.validate(
               %{capability | evidence_ids: [measurement_claim.id]},
               result.bundle
             )

    assert {:error, _} = Capability.new(%{}, result.bundle)
    assert {:error, _} = Capability.validate(:bad, result.bundle)
    assert {:error, _} = Capability.to_map(:bad, result.bundle)
    assert {:error, _} = Capability.validate(capability, :bad)
  end

  property "independent signed field and power expectations remain exact" do
    check all(
            temperature <- integer(-32_767..32_767),
            humidity <- integer(0..40_000),
            battery <- integer(0..2046),
            tx <- integer(0..30)
          ) do
      {:ok, result} =
        RuuviRawV2.decode(capture(frame(temperature, humidity, bor(bsl(battery, 5), tx), 0, 0)))

      values = Map.new(result.measurements, &{&1.kind, &1.value})
      assert values["temperature"] === temperature / 200
      assert values["humidity"] === humidity / 400
      assert values["batteryVoltage"] === (battery + 1600) / 1000
      assert values["txPower"] === tx * 2 - 40
    end
  end

  defp capture(bytes),
    do: Fixtures.observation(%{payload: {:bytes, bytes}, transport: %{"manufacturer_id" => 1177}})

  defp frame(temperature, humidity, power, movement, sequence),
    do:
      <<5, temperature::signed-16, humidity::16, 0::16, 0::signed-16, 0::signed-16, 0::signed-16,
        power::16, movement, sequence::16, 0::48>>
end
