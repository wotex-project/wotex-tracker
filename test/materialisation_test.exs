defmodule Wotex.Tracker.MaterialisationTest do
  use ExUnit.Case, async: true

  alias Wotex.Tracker.{
    Capability,
    Catalogue,
    Decoder,
    Deployment,
    Error,
    EvidenceBundle,
    Fixtures,
    Identity,
    Materialisation,
    Model,
    Resolution
  }

  alias Wotex.Tracker.Decoders.RuuviRawV2

  setup do
    %{input: Fixtures.materialisation_input()}
  end

  test "complete imported fixture produces the independent fixed canonical TD", %{input: input} do
    assert {:ok, materialised} = Materialisation.new(input)
    assert {:ok, expected} = Wotex.JSON.decode(File.read!("test/fixtures/ruuvi/ordinary.td.json"))
    assert Wotex.ThingDescription.to_map(materialised.td) === expected
    assert {:ok, canonical} = Wotex.ThingDescription.encode(materialised.td, :canonical)
    assert {:ok, ^canonical} = Wotex.JSON.encode(expected)
    refute canonical =~ "cbb8334c884f"
    refute canonical =~ "observation-1"
    refute canonical =~ "fixture-receiver"
    assert materialised.bundle === input.bundle
    assert materialised.provenance["catalogue"] == input.catalogue.identity
    assert materialised.provenance["model"] == input.model.identity
    assert {:ok, ^materialised} = Materialisation.new(Map.new(Enum.reverse(Map.to_list(input))))
    assert [] == Application.spec(:wotex_tracker, :mod)
  end

  test "optional omission is exact, while mandatory capability and Form absence fail", %{
    input: input
  } do
    temperature = Enum.find(input.capabilities, &(&1.id == "temperature"))
    assert {:ok, only_temperature} = Materialisation.new(%{input | capabilities: [temperature]})

    assert Map.keys(Wotex.ThingDescription.to_map(only_temperature.td)["properties"]) == [
             "temperature"
           ]

    assert {:error, %Error{code: :missing_capability}} =
             Materialisation.new(%{input | capabilities: []})

    assert {:error, %Error{code: :conflict}} =
             Materialisation.new(%{input | capabilities: [temperature, temperature]})

    deployment =
      redeploy(input.deployment, %{
        forms: Map.delete(input.deployment.forms, "/properties/temperature")
      })

    assert {:error, %Error{code: :missing_form}} =
             Materialisation.new(%{input | deployment: deployment})

    assert {:error, _} = Materialisation.new(%{input | capabilities: [:forged]})
    assert {:error, _} = Materialisation.new(%{input | capabilities: [temperature | :bad]})
  end

  test "model extension types and false/zero native values are preserved", %{input: input} do
    document =
      input.model.document
      |> Map.put("@type", ["tm:ThingModel", "ex:Sensor"])
      |> Map.put("x-native", %{
        "false" => false,
        "int" => 1,
        "float" => 1.0,
        "zero" => 0,
        "null" => nil
      })

    {:ok, model} = Model.new(document, input.model.revision)
    assert {:ok, result} = Materialisation.new(%{input | model: model})
    td = Wotex.ThingDescription.to_map(result.td)
    assert td["@type"] === ["ex:Sensor"]
    assert td["x-native"] === document["x-native"]
    refute Map.has_key?(td, "tm:optional")
    {:ok, model} = Model.new(Map.put(document, "@type", ["tm:ThingModel"]), input.model.revision)
    assert {:ok, result} = Materialisation.new(%{input | model: model})
    refute Map.has_key?(Wotex.ThingDescription.to_map(result.td), "@type")
  end

  test "escaped optional pointers and mapping destinations use upstream pointer semantics", %{
    input: input
  } do
    name = "room/temp~sensor"
    pointer = "/properties/room~1temp~0sensor"

    document =
      input.model.document
      |> Map.put("properties", %{
        name => %{"type" => "number", "unit" => "Cel", "readOnly" => true}
      })
      |> Map.put("tm:optional", [pointer])

    {:ok, model} = Model.new(document, input.model.revision)
    input = reprofile(input, %{mapping: %{"temperature" => pointer}})
    form = input.deployment.forms["/properties/temperature"]
    deployment = redeploy(input.deployment, %{forms: %{pointer => form}})
    assert {:ok, result} = Materialisation.new(%{input | model: model, deployment: deployment})
    assert Map.has_key?(Wotex.ThingDescription.to_map(result.td)["properties"], name)

    assert {:ok, result} =
             Materialisation.new(%{
               input
               | model: model,
                 deployment: deployment,
                 capabilities: []
             })

    assert Wotex.ThingDescription.to_map(result.td)["properties"] == %{}
  end

  test "unsupported composition, references and placeholders fail explicitly", %{input: input} do
    for document <- [
          put_in(
            input.model.document,
            ["properties", "temperature", "tm:ref"],
            "https://example.invalid/model#/properties/temperature"
          ),
          Map.put(input.model.document, "title", "{{title}}"),
          Map.put(input.model.document, "links", [
            %{"href" => "https://example.invalid/model", "rel" => "tm:extends"}
          ]),
          Map.put(input.model.document, "events", %{"event" => %{}})
        ] do
      assert {:error, %Error{code: :unsupported_model_feature}} =
               Model.new(document, input.model.revision)
    end

    assert {:error, _} =
             Model.new(
               Map.put(input.model.document, "tm:optional", ["/properties/missing"]),
               input.model.revision
             )

    assert {:error, _} =
             Model.new(Map.put(input.model.document, "@context", false), input.model.revision)

    assert {:error, _} = Model.new([], input.model.revision)
    assert {:error, _} = Model.new(input.model.document, :bad)
    assert {:error, _} = Model.validate(:forged)
    assert {:error, _} = Model.validate(%{input.model | identity: "forged"})
    assert {:error, _} = Model.new(input.model.document, input.model.revision, max_affordances: 1)

    assert {:error, _} =
             Model.new(input.model.document, input.model.revision, max_material_bytes: 1)
  end

  test "qualified Action capabilities materialise without claiming execution" do
    input = action_input()
    action = Enum.find(input.capabilities, &(&1.kind == :action))

    assert {:ok, projected} = Capability.to_map(action, input.bundle)

    assert projected == %{
             "evidence_ids" => action.evidence_ids,
             "id" => "requestLocation",
             "kind" => "action",
             "operations" => ["invoke"],
             "unit" => nil
           }

    assert {:ok, result} = Materialisation.new(input)
    td = Wotex.ThingDescription.to_map(result.td)

    assert td["actions"]["requestLocation"] == %{
             "description" => "Requests a new device report without claiming delivery",
             "input" => %{"maximum" => 300, "minimum" => 1, "type" => "integer", "unit" => "s"},
             "output" => %{"type" => "string"},
             "safe" => false,
             "idempotent" => false,
             "forms" => [
               %{
                 "contentType" => "application/json",
                 "href" => "https://fixture.example.invalid/actions/request-location",
                 "op" => ["invokeaction"]
               }
             ]
           }

    decoded = input.decoded

    assert {:ok, ^decoded} =
             Decoder.validate(input.decoded, input.observation, input.catalogue)

    property_capabilities = Enum.reject(input.capabilities, &(&1.kind == :action))

    assert {:error, %Error{code: :missing_capability}} =
             Materialisation.new(%{input | capabilities: property_capabilities})

    optional_model =
      input.model.document
      |> Map.put(
        "tm:optional",
        input.model.document["tm:optional"] ++ ["/actions/requestLocation"]
      )
      |> then(fn document -> Model.new(document, input.model.revision) end)

    assert {:ok, optional_model} = optional_model

    assert {:ok, optional} =
             Materialisation.new(%{
               input
               | model: optional_model,
                 capabilities: property_capabilities
             })

    assert optional.td |> Wotex.ThingDescription.to_map() |> Map.fetch!("actions") == %{}

    missing_form =
      redeploy(input.deployment, %{
        forms: Map.delete(input.deployment.forms, "/actions/requestLocation")
      })

    assert {:error, %Error{code: :missing_form}} =
             Materialisation.new(%{input | deployment: missing_form})
  end

  test "Action declarations require exact invocation Forms and bounded trusted output", %{
    input: base
  } do
    input = action_input()
    data = input.deployment |> Map.from_struct() |> Map.delete(:identity)
    pointer = "/actions/requestLocation"
    form = hd(data.forms[pointer])

    for changed <- [
          Map.delete(form, "op"),
          %{form | "op" => ["invokeaction", "queryaction"]},
          %{form | "op" => "readproperty"},
          %{form | "href" => "/relative"},
          %{form | "href" => "https://user:password@example.invalid/action"}
        ] do
      assert {:error, _} =
               Deployment.new(%{data | forms: Map.put(data.forms, pointer, [changed])})
    end

    assert {:error, _} =
             Deployment.new(%{data | observation_evidence: %{pointer => "transport-evidence"}})

    assert {:error, %Error{code: :invalid_decoder_result}} =
             Decoder.run(
               base.observation,
               base.resolution,
               base.catalogue,
               {RuuviRawV2.revision(),
                fn observation ->
                  {:ok, output} = RuuviRawV2.decode(observation)
                  {:ok, Map.put(output, :actions, ["duplicate", "duplicate"])}
                end}
             )

    assert {:error, %Error{code: :invalid_decoder_result}} =
             Decoder.run(
               base.observation,
               base.resolution,
               base.catalogue,
               {RuuviRawV2.revision(),
                fn observation ->
                  {:ok, output} = RuuviRawV2.decode(observation)
                  {:ok, Map.put(output, :actions, [""])}
                end}
             )
  end

  test "duplicate mappings and incompatible Property semantics are rejected", %{input: input} do
    duplicate = Map.put(input.resolution.selected.mapping, "humidity", "/properties/temperature")

    assert {:error, %Error{code: :invalid_mapping}} =
             Materialisation.new(reprofile(input, %{mapping: duplicate}))

    missing = Map.put(input.resolution.selected.mapping, "temperature", "/properties/missing")

    assert {:error, %Error{code: :invalid_mapping}} =
             Materialisation.new(reprofile(input, %{mapping: missing}))

    for {key, value} <- [
          {"readOnly", false},
          {"writeOnly", true},
          {"observable", true},
          {"unit", "K"}
        ] do
      {:ok, model} =
        Model.new(
          put_in(input.model.document, ["properties", "temperature", key], value),
          input.model.revision
        )

      assert {:error, %Error{code: :invalid_mapping}} =
               Materialisation.new(%{input | model: model})
    end

    deployment =
      redeploy(input.deployment, %{
        forms:
          Map.put(
            input.deployment.forms,
            "/properties/unknown",
            input.deployment.forms["/properties/temperature"]
          )
      })

    assert {:error, %Error{code: :invalid_mapping}} =
             Materialisation.new(%{input | deployment: deployment})
  end

  test "snapshot substitution, stale revisions and forged decoded results cannot materialise", %{
    input: input
  } do
    assert {:error, %Error{code: :revision_mismatch}} =
             Materialisation.new(%{input | mapping_revision: "different"})

    document = put_in(input.model.document, ["version", "model"], "2")
    {:ok, model} = Model.new(document, {elem(input.model.revision, 0), "2"})

    assert {:error, %Error{code: :revision_mismatch}} =
             Materialisation.new(%{input | model: model})

    {:ok, changed_catalogue} =
      Catalogue.new([%{input.resolution.selected | source_provenance: %{"changed" => true}}])

    {:ok, changed_resolution} = Resolution.resolve(input.observation, changed_catalogue)

    assert {:error, %Error{code: :conflict}} =
             Materialisation.new(%{
               input
               | catalogue: changed_catalogue,
                 resolution: changed_resolution
             })

    assert {:error, _} =
             Materialisation.new(%{input | decoded: %{input.decoded | capabilities: []}})

    assert {:error, _} =
             Decoder.validate(
               %{input.decoded | measurements: []},
               input.observation,
               input.catalogue
             )

    assert {:error, _} = Decoder.validate(:bad, input.observation, input.catalogue)
    {:ok, no_identity_bundle} = EvidenceBundle.new([input.observation], [])

    assert {:error, _} =
             Decoder.validate(
               %{input.decoded | bundle: no_identity_bundle},
               input.observation,
               input.catalogue
             )

    for value <- [nil, %{}, input.model], do: assert({:error, _} = Materialisation.new(value))
    unknown_observation = %{input.observation | payload: {:bytes, <<>>}}
    {:ok, resolution} = Resolution.resolve(unknown_observation, input.catalogue)

    assert {:error, %Error{code: :unknown_resolution}} =
             Materialisation.new(%{
               input
               | observation: unknown_observation,
                 resolution: resolution
             })
  end

  test "deployment requires explicit security, exact read operations and bounded Forms", %{
    input: input
  } do
    data = input.deployment |> Map.from_struct() |> Map.delete(:identity)

    for change <- [
          %{security: []},
          %{security: ["missing"]},
          %{security: ["bearer", "bearer"]},
          %{security_definitions: %{}},
          %{security_definitions: %{"bearer" => %{}}},
          %{security_definitions: []},
          %{forms: nil},
          %{forms: %{"/properties/temperature" => []}},
          %{forms: %{"/properties/temperature" => [:bad]}}
        ] do
      assert {:error, _} = Deployment.new(Map.merge(data, change))
    end

    form = hd(data.forms["/properties/temperature"])

    for changed <- [
          Map.delete(form, "op"),
          %{form | "op" => "writeproperty"},
          %{form | "href" => "/relative"},
          %{form | "href" => "https://user:password@example.invalid/"},
          %{form | "href" => "https://example.invalid/{{path}}"},
          Map.put(form, "security", ["missing"])
        ] do
      assert {:error, _} =
               Deployment.new(%{data | forms: %{"/properties/temperature" => [changed]}})
    end

    for size <- [7, 8] do
      assert {:ok, _} =
               Deployment.new(%{
                 data
                 | forms: %{"/properties/temperature" => List.duplicate(form, size)}
               })
    end

    assert {:error, _} =
             Deployment.new(%{
               data
               | forms: %{"/properties/temperature" => List.duplicate(form, 9)}
             })

    assert {:error, _} = Deployment.new(data, max_affordances: 1)
    assert {:error, _} = Deployment.new(data, max_material_bytes: 1)
    assert {:error, _} = Deployment.validate(:forged)
    assert {:error, _} = Deployment.validate(%{input.deployment | identity: "forged"})
    assert {:error, _} = Deployment.new(%{})

    assert {:ok, _} =
             Deployment.new(%{
               data
               | forms: %{"/properties/temperature" => [Map.put(form, "security", "bearer")]}
             })
  end

  test "generation binds full deployment and model data, including unused optional Forms", %{
    input: input
  } do
    {:ok, before} = Materialisation.new(input)

    for changes <- [
          %{revision: "deployment-2"},
          %{title: "Changed title"},
          %{
            forms:
              put_in(input.deployment.forms, ["/properties/temperature"], [
                %{"href" => "https://other.example.invalid/temp", "op" => ["readproperty"]}
              ])
          }
        ] do
      assert {:ok, after_change} =
               Materialisation.new(%{input | deployment: redeploy(input.deployment, changes)})

      refute before.identity === after_change.identity
    end

    temperature = Enum.find(input.capabilities, &(&1.id == "temperature"))
    {:ok, first} = Materialisation.new(%{input | capabilities: [temperature]})

    deployment =
      redeploy(input.deployment, %{
        forms: Map.delete(input.deployment.forms, "/properties/humidity")
      })

    {:ok, second} =
      Materialisation.new(%{input | capabilities: [temperature], deployment: deployment})

    assert first.td === second.td
    refute first.identity === second.identity
  end

  test "the 64-affordance budget is enforced before construction", %{input: input} do
    for size <- [63, 64] do
      properties =
        Map.new(1..size, &{"p#{&1}", %{"type" => "number", "unit" => "Cel", "readOnly" => true}})

      document =
        input.model.document |> Map.put("properties", properties) |> Map.put("tm:optional", [])

      assert {:ok, _} = Model.new(document, input.model.revision)
    end

    properties =
      Map.new(1..65, &{"p#{&1}", %{"type" => "number", "unit" => "Cel", "readOnly" => true}})

    document =
      input.model.document |> Map.put("properties", properties) |> Map.put("tm:optional", [])

    assert {:error, %Error{code: :limit_exceeded}} = Model.new(document, input.model.revision)

    action = %{
      "input" => %{"type" => "integer", "minimum" => 1},
      "output" => %{"type" => "string"}
    }

    for {property_count, expected} <- [{63, :ok}, {64, :error}] do
      properties =
        Map.new(
          1..property_count,
          &{"p#{&1}", %{"type" => "number", "unit" => "Cel", "readOnly" => true}}
        )

      document =
        input.model.document
        |> Map.put("properties", properties)
        |> Map.put("actions", %{"requestLocation" => action})
        |> Map.put("tm:optional", [])

      assert {^expected, _} = Model.new(document, input.model.revision)
    end

    document = put_in(input.model.document, ["properties", "temperature", "tm:optional"], [])

    assert {:error, %Error{code: :unsupported_model_feature}} =
             Model.new(document, input.model.revision)
  end

  test "missing samples preserve the TD while changing private evidence generation", %{
    input: input
  } do
    {:ok, ordinary} = Materialisation.new(input)

    observation = %{
      input.observation
      | id: "unavailable-capture",
        payload: {:bytes, Base.decode16!("058000FFFFFFFF800080008000FFFFFFFFFFFFFFFFFFFFFF")}
    }

    {:ok, resolution} = Resolution.resolve(observation, input.catalogue)

    {:ok, decoded} =
      Decoder.run(
        observation,
        resolution,
        input.catalogue,
        {RuuviRawV2.revision(), &RuuviRawV2.decode/1}
      )

    association = %{
      input.bundle.evidence["identity-1"]
      | source_observation_ids: [observation.id]
    }

    {:ok, bundle} =
      EvidenceBundle.new([observation], [association | Map.values(decoded.bundle.evidence)])

    {:ok, identity} = Identity.new(Fixtures.identity_input(), bundle)

    changed = %{
      input
      | observation: observation,
        resolution: resolution,
        decoded: decoded,
        capabilities: decoded.capabilities,
        bundle: bundle,
        identity: identity
    }

    assert {:ok, unavailable} = Materialisation.new(changed)
    assert unavailable.td === ordinary.td
    refute unavailable.identity === ordinary.identity
  end

  defp redeploy(deployment, changes) do
    {:ok, deployment} =
      deployment
      |> Map.from_struct()
      |> Map.delete(:identity)
      |> Map.merge(changes)
      |> Deployment.new()

    deployment
  end

  defp reprofile(input, changes) do
    profile = Map.merge(input.resolution.selected, changes)
    {:ok, catalogue} = Catalogue.new([profile])
    {:ok, resolution} = Resolution.resolve(input.observation, catalogue)

    {:ok, decoded} =
      Decoder.run(
        input.observation,
        resolution,
        catalogue,
        {RuuviRawV2.revision(), &RuuviRawV2.decode/1}
      )

    association = input.bundle.evidence["identity-1"]

    {:ok, bundle} =
      EvidenceBundle.new([input.observation], [association | Map.values(decoded.bundle.evidence)])

    {:ok, identity} = Identity.new(Fixtures.identity_input(), bundle)

    %{
      input
      | catalogue: catalogue,
        resolution: resolution,
        decoded: decoded,
        capabilities: decoded.capabilities,
        bundle: bundle,
        identity: identity
    }
  end

  defp action_input do
    input = Fixtures.materialisation_input()
    pointer = "/actions/requestLocation"

    action = %{
      "description" => "Requests a new device report without claiming delivery",
      "input" => %{"type" => "integer", "unit" => "s", "minimum" => 1, "maximum" => 300},
      "output" => %{"type" => "string"},
      "safe" => false,
      "idempotent" => false
    }

    {:ok, model} =
      input.model.document
      |> Map.put("actions", %{"requestLocation" => action})
      |> then(&Model.new(&1, input.model.revision))

    profile = %{
      input.resolution.selected
      | mapping: Map.put(input.resolution.selected.mapping, "requestLocation", pointer)
    }

    {:ok, catalogue} = Catalogue.new([profile])
    {:ok, resolution} = Resolution.resolve(input.observation, catalogue)

    decoder = fn observation ->
      with {:ok, output} <- RuuviRawV2.decode(observation),
           do: {:ok, Map.put(output, :actions, ["requestLocation"])}
    end

    {:ok, decoded} =
      Decoder.run(
        input.observation,
        resolution,
        catalogue,
        {RuuviRawV2.revision(), decoder}
      )

    association = input.bundle.evidence["identity-1"]

    {:ok, bundle} =
      EvidenceBundle.new(
        [input.observation],
        [association | Map.values(decoded.bundle.evidence)]
      )

    {:ok, identity} = Identity.new(Fixtures.identity_input(), bundle)

    form = %{
      "href" => "https://fixture.example.invalid/actions/request-location",
      "op" => ["invokeaction"],
      "contentType" => "application/json"
    }

    deployment =
      redeploy(input.deployment, %{
        forms: Map.put(input.deployment.forms, pointer, [form])
      })

    %{
      input
      | catalogue: catalogue,
        resolution: resolution,
        decoded: decoded,
        bundle: bundle,
        capabilities: decoded.capabilities,
        identity: identity,
        model: model,
        deployment: deployment
    }
  end
end
