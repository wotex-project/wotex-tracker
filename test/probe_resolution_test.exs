defmodule Wotex.Tracker.ProbeResolutionTest do
  use ExUnit.Case, async: true

  alias Wotex.Tracker.{
    Catalogue,
    Decoder,
    DeviceProfile,
    Error,
    Fixtures,
    Observation,
    ProbeContract,
    ProbeEvidence,
    Resolution
  }

  test "a matching declared probe promotes only its passive candidate and feeds decoding" do
    observation = Fixtures.observation()
    profile = profile()
    other = Fixtures.profile(%{id: "other", confidence: :candidate})
    {:ok, catalogue} = Catalogue.new([profile, other])

    assert {:ok, %{status: :unknown, reason: :insufficient_evidence}} =
             Resolution.resolve(observation, catalogue)

    result = result(observation, profile, <<0, 1, 255>>)

    assert {:ok, resolution} = Wotex.Tracker.resolve_with_probe(observation, catalogue, result)
    assert resolution.status == :resolved
    assert resolution.reason == :unique_best_match
    assert resolution.selected === profile
    assert resolution.confidence == :strong
    assert resolution.probe_evidence.identity =~ "wtr-json-v1:sha256:"

    assert %{confidence: :strong, reasons: reasons} =
             Enum.find(resolution.candidates, &(&1.profile == {profile.id, profile.version}))

    assert "declared_active_probe_matched" in reasons
    assert {:ok, ^resolution} = Resolution.validate(resolution, observation, catalogue)

    assert {:error, %Error{code: :conflict}} =
             Resolution.validate(%{resolution | confidence: :exact}, observation, catalogue)

    invalid_evidence = %{
      resolution.probe_evidence
      | document: Map.put(result, "schema", "invalid")
    }

    assert {:error, %Error{}} =
             Resolution.validate(
               %{resolution | probe_evidence: invalid_evidence},
               observation,
               catalogue
             )

    assert {:error, %Error{code: :conflict}} =
             Resolution.validate(:forged, observation, catalogue)

    callback = fn _ ->
      {:ok,
       %{
         measurements: [],
         positions: [],
         identity: %{"assurance" => "probe-qualified-profile-family"}
       }}
    end

    assert {:ok, decoded} =
             Decoder.run(observation, resolution, catalogue, {profile.decoder, callback})

    assert [identity] = Map.values(decoded.bundle.evidence)
    assert identity.confidence == :strong
    assert "declared_active_probe_evidence" in identity.reasons
  end

  test "an informative mismatch rejects one ambiguous profile and an uninformative one does not" do
    observation = Fixtures.observation()
    rejected = profile(%{id: "rejected", confidence: :strong})
    remaining = Fixtures.profile(%{id: "remaining", confidence: :strong})
    {:ok, catalogue} = Catalogue.new([rejected, remaining])

    assert {:ok, %{status: :ambiguous}} = Resolution.resolve(observation, catalogue)

    assert {:ok, resolution} =
             Resolution.resolve_with_probe(
               observation,
               catalogue,
               result(observation, rejected, <<9>>)
             )

    assert resolution.status == :resolved
    assert resolution.selected === remaining
    assert resolution.confidence == :strong
    assert Enum.map(resolution.candidates, & &1.profile) == [{"remaining", "1"}]

    uninformative =
      profile(%{
        id: "uninformative",
        probes: [probe(%{"mismatch" => "uninformative"})]
      })

    {:ok, catalogue} = Catalogue.new([uninformative])

    assert {:ok, resolution} =
             Resolution.resolve_with_probe(
               observation,
               catalogue,
               result(observation, uninformative, <<9>>)
             )

    assert resolution.status == :unknown
    assert resolution.confidence == nil
    assert [%{reasons: reasons}] = resolution.candidates
    assert "declared_active_probe_uninformative" in reasons
  end

  test "decoded evidence identities bind the effective confidence and probe evidence" do
    observation = Fixtures.observation()

    profile =
      profile(%{
        id: "strong-probe",
        confidence: :strong,
        probes: [probe(%{"match_confidence" => "exact"})]
      })

    {:ok, catalogue} = Catalogue.new([profile])
    {:ok, passive} = Resolution.resolve(observation, catalogue)

    {:ok, active} =
      Resolution.resolve_with_probe(
        observation,
        catalogue,
        result(observation, profile, <<0, 1, 255>>)
      )

    callback = fn _ ->
      {:ok,
       %{
         measurements: [],
         positions: [],
         identity: %{"assurance" => "same-decoder-output"}
       }}
    end

    assert {:ok, passive_decoded} =
             Decoder.run(observation, passive, catalogue, {profile.decoder, callback})

    assert {:ok, active_decoded} =
             Decoder.run(observation, active, catalogue, {profile.decoder, callback})

    assert passive.confidence == :strong
    assert active.confidence == :exact
    assert [passive_id] = Map.keys(passive_decoded.bundle.evidence)
    assert [active_id] = Map.keys(active_decoded.bundle.evidence)
    refute passive_id == active_id
  end

  test "probe results are exact, canonical and bound to observation, profile and target" do
    observation = Fixtures.observation()
    profile = profile()
    {:ok, catalogue} = Catalogue.new([profile])
    valid = result(observation, profile, <<0, 1, 255>>)

    assert {:ok, evidence} = ProbeEvidence.new(valid, observation, catalogue)
    assert evidence.value == <<0, 1, 255>>
    assert {:ok, ^evidence} = ProbeEvidence.validate(evidence, observation, catalogue)

    invalid = [
      Map.put(valid, "schema", "wtr.active-probe-result.v2"),
      Map.put(valid, "request_id", "not-a-request"),
      Map.put(valid, "request_id", 1),
      Map.put(valid, "observation_identity", String.duplicate("0", 64)),
      put_in(valid, ["profile", "id"], "other"),
      put_in(valid, ["profile", "version"], 1),
      put_in(valid, ["probe", "id"], "other"),
      put_in(valid, ["probe", "revision"], 1),
      Map.put(valid, "transport", "other"),
      Map.put(valid, "operation", "write"),
      put_in(valid, ["target", "characteristic_uuid"], "2a24"),
      put_in(valid, ["target", "handle"], 0),
      put_in(valid, ["target", "extra"], true),
      Map.put(valid, "target_identity", String.duplicate("A", 64)),
      Map.put(valid, "target_identity", 1),
      put_in(valid, ["value", "encoding"], "hex"),
      put_in(valid, ["value", "bytes"], 2),
      put_in(valid, ["value", "data"], "AA"),
      Map.put(valid, "extra", true)
    ]

    for document <- invalid do
      assert {:error, %Error{}} = ProbeEvidence.new(document, observation, catalogue)
      assert {:error, %Error{}} = Resolution.resolve_with_probe(observation, catalogue, document)
    end

    oversized = result(observation, profile, :binary.copy(<<0>>, 33))
    assert {:error, %Error{}} = ProbeEvidence.new(oversized, observation, catalogue)

    nullable_target =
      valid
      |> put_in(["target", "handle"], nil)
      |> put_in(["target", "generation"], nil)

    assert {:ok, _} = ProbeEvidence.new(nullable_target, observation, catalogue)

    full_uuid_target =
      valid
      |> put_in(["target", "service_uuid"], "0000180a-0000-1000-8000-00805f9b34fb")
      |> put_in(["target", "characteristic_uuid"], "00002a29-0000-1000-8000-00805f9b34fb")

    assert {:ok, _} = ProbeEvidence.new(full_uuid_target, observation, catalogue)

    assert {:error, %Error{}} =
             ProbeEvidence.validate(%{evidence | identity: "forged"}, observation, catalogue)

    assert {:error, %Error{}} = ProbeEvidence.validate(:forged, observation, catalogue)
  end

  test "a probe cannot introduce a profile that passive evidence did not nominate" do
    observation = Fixtures.observation(%{payload: {:bytes, <<6, 0>>}})
    profile = profile()
    {:ok, catalogue} = Catalogue.new([profile])

    assert {:ok, %{status: :unknown, reason: :no_match}} =
             Resolution.resolve(observation, catalogue)

    assert {:error, %Error{code: :conflict}} =
             Resolution.resolve_with_probe(
               observation,
               catalogue,
               result(observation, profile, <<0, 1, 255>>)
             )
  end

  test "profile probe declarations reject executable, duplicate, weak and unbounded shapes" do
    assert {:ok, contract} = ProbeContract.new(probe())
    assert {:ok, true} = ProbeContract.match?(contract, <<0, 1, 255>>)
    assert {:ok, false} = ProbeContract.match?(contract, <<0, 1, 0>>)
    assert {:error, %Error{}} = ProbeContract.match?(contract, :not_bytes)
    assert {:error, %Error{}} = ProbeContract.validate(%{contract | predicates: []})

    assert {:error, %Error{}} =
             ProbeContract.validate(%ProbeContract{document: %{}, predicates: []})

    assert {:error, %Error{}} = ProbeContract.validate(:forged)
    assert {:error, %Error{}} = ProbeContract.match?(:forged, <<0>>)

    exact_probe = probe(%{"match_confidence" => "exact"})
    assert {:ok, exact_contract} = ProbeContract.new(exact_probe)
    assert ProbeContract.promotion(exact_contract) == :exact
    assert ProbeContract.equivalent_uuid?("0000180a", "0000180a-0000-1000-8000-00805f9b34fb")
    refute ProbeContract.equivalent_uuid?(:invalid, "180a")

    byte_probe =
      probe(%{
        "predicates" => [
          %{"op" => "length", "value" => 3},
          %{"op" => "byte", "offset" => 1, "value" => 1}
        ]
      })

    assert {:ok, byte_contract} = ProbeContract.new(byte_probe)
    assert {:ok, true} = ProbeContract.match?(byte_contract, <<0, 1, 2>>)
    assert {:ok, false} = ProbeContract.match?(byte_contract, <<0>>)

    invalid = [
      Map.put(probe(), "callback", "Danger"),
      Map.put(probe(), "transport", "shell"),
      Map.put(probe(), "operation", "write"),
      Map.put(probe(), "timeout_ms", 31),
      Map.put(probe(), "max_value_bytes", 0),
      Map.put(probe(), "predicates", []),
      Map.put(probe(), "predicates", [%{"op" => "length", "value" => 3}]),
      Map.put(probe(), "predicates", [%{"op" => "unknown"}]),
      Map.put(probe(), "predicates", [
        %{"op" => "bytes", "offset" => 0, "encoding" => "base64", "data" => "AA"}
      ]),
      Map.put(probe(), "match_confidence", "candidate"),
      Map.put(probe(), "mismatch", "guess"),
      Map.put(probe(), "failure", "reject"),
      Map.put(probe(), "failure", "guess"),
      put_in(probe(), ["target", "service_uuid"], 0x180A)
    ]

    for document <- invalid, do: assert({:error, %Error{}} = ProbeContract.new(document))

    assert {:error, %Error{code: :invalid_profile}} =
             DeviceProfile.new(Fixtures.profile_input(%{confidence: :exact, probes: [probe()]}))

    duplicate = [probe(), probe()]

    assert {:error, %Error{code: :invalid_profile}} =
             DeviceProfile.new(Fixtures.profile_input(%{probes: duplicate}))

    assert {:error, %Error{code: :limit_exceeded}} =
             DeviceProfile.new(Fixtures.profile_input(%{probes: List.duplicate(probe(), 33)}))

    admitted = profile()
    assert {:ok, document} = DeviceProfile.to_map(admitted)
    assert document["schema"] == "wtr.profile.v2"
    assert document["probes"] == [probe()]

    {:ok, plain_identity} = DeviceProfile.identity(Fixtures.profile(%{confidence: :candidate}))
    {:ok, probe_identity} = DeviceProfile.identity(admitted)
    refute probe_identity == plain_identity
  end

  defp profile(changes \\ %{}) do
    changes = Map.put_new(changes, :confidence, :candidate)
    changes = Map.put_new(changes, :probes, [probe()])
    Fixtures.profile(changes)
  end

  defp probe(changes \\ %{}) do
    Map.merge(
      %{
        "id" => "device-information",
        "revision" => "1",
        "transport" => "ble_gatt",
        "operation" => "read",
        "target" => %{
          "service_uuid" => "180a",
          "characteristic_uuid" => "2a29"
        },
        "timeout_ms" => 1_000,
        "max_value_bytes" => 32,
        "predicates" => [
          %{"op" => "length", "value" => 3},
          %{"op" => "bytes", "offset" => 0, "encoding" => "base64", "data" => "AAH/"}
        ],
        "match_confidence" => "strong",
        "mismatch" => "reject",
        "failure" => "unavailable"
      },
      changes
    )
  end

  defp result(observation, profile, value) do
    {:ok, observation_identity} = Observation.identity(observation)
    probe = hd(profile.probes)

    %{
      "schema" => "wtr.active-probe-result.v1",
      "request_id" => "12345678-1234-4234-8234-123456789abc",
      "observation_identity" => observation_identity,
      "profile" => %{"id" => profile.id, "version" => profile.version},
      "probe" => %{"id" => probe["id"], "revision" => probe["revision"]},
      "transport" => "ble_gatt",
      "operation" => "read",
      "target" => %{
        "service_uuid" => "180a",
        "characteristic_uuid" => "2a29",
        "handle" => 37,
        "generation" => 9
      },
      "target_identity" => String.duplicate("a", 64),
      "value" => %{
        "encoding" => "base64",
        "bytes" => byte_size(value),
        "data" => Base.encode64(value)
      }
    }
  end
end
