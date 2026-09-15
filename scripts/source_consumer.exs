# Runs from an isolated production consumer, using only installed archive files.
alias Wotex.Tracker
alias Wotex.Tracker.{Deployment, Evidence, EvidenceBundle, Identity, Model}
alias Wotex.Tracker.Decoders.RuuviRawV2

[] = Application.spec(:wotex_tracker, :mod)

for module <- [Phoenix, Wotex.Runtime, Wotex.Directory, Nx, Nerves] do
  false = Code.ensure_loaded?(module)
end

{:ok, document} =
  Wotex.JSON.decode(
    File.read!(
      Application.app_dir(
        :wotex_tracker,
        "priv/thing_models/environmental-sensor-1.0.0.tm.json"
      )
    )
  )

{:ok, profile} = RuuviRawV2.profile()
{:ok, catalogue} = Tracker.catalogue([profile])

{:ok, observation} =
  Tracker.observation(%{
    id: "archive-fixture",
    observed_at: 1_700_000_000_000,
    ingress: "ble",
    source: %{"receiver_id" => "archive-consumer"},
    addressing: %{},
    radio: %{},
    transport: %{"manufacturer_id" => 1177},
    provenance: %{"kind" => "fixture", "source" => "ruuvi-documentation"},
    payload: {:bytes, Base.decode16!("0512FC5394C37C0004FFFC040CAC364200CDCBB8334C884F")}
  })

before_processes = MapSet.new(Process.list())

{:ok, imported} =
  Tracker.import_observation(
    observation,
    catalogue,
    {RuuviRawV2.revision(), &RuuviRawV2.decode/1}
  )

thing_id = "urn:uuid:aca49b80-1e09-40cf-929e-b193047f6ca9"

{:ok, association} =
  Evidence.new(%{
    id: "operator-association",
    kind: :identity,
    claim: %{"thing_id" => thing_id, "strategy" => "operator-pseudonym-v1", "revision" => "1"},
    source_observation_ids: [observation.id],
    evidence_ids: [],
    profile: {profile.id, profile.version},
    decoder: profile.decoder,
    confidence: :exact,
    reasons: ["synthetic_operator_fixture"],
    association_id: "enrollment-1"
  })

{:ok, bundle} =
  EvidenceBundle.new([observation], [association | Map.values(imported.decoded.bundle.evidence)])

{:ok, identity} =
  Identity.new(
    %{
      thing_id: thing_id,
      association_id: "enrollment-1",
      revision: "1",
      evidence_id: association.id
    },
    bundle
  )

{:ok, model} = Model.new(document, profile.model)

forms =
  Map.new(profile.mapping, fn {name, pointer} ->
    {pointer,
     [
       %{
         "href" => "https://operator.example.invalid/properties/" <> name,
         "op" => "readproperty",
         "contentType" => "application/json"
       }
     ]}
  end)

{:ok, deployment} =
  Deployment.new(%{
    revision: "fixture-deployment",
    title: "Archive fixture sensor",
    forms: forms,
    security_definitions: %{"token" => %{"scheme" => "bearer"}},
    security: ["token"]
  })

{:ok, materialised} =
  Tracker.materialize(%{
    observation: observation,
    catalogue: catalogue,
    resolution: imported.resolution,
    decoded: imported.decoded,
    bundle: bundle,
    capabilities: imported.decoded.capabilities,
    identity: identity,
    model: model,
    mapping_revision: profile.mapping_revision,
    deployment: deployment
  })

td = Wotex.ThingDescription.to_map(materialised.td)
^thing_id = td["id"]
10 = map_size(td["properties"])
"Cel" = td["properties"]["temperature"]["unit"]
{:ok, encoded} = Wotex.ThingDescription.encode(materialised.td, :canonical)
false = String.contains?(encoded, "cbb8334c884f")
true = MapSet.subset?(MapSet.new(Process.list()), before_processes)
{:ok, empty} = Tracker.catalogue([])

{:ok, %{decoded: nil, resolution: %{status: :unknown}}} =
  Tracker.import_observation(observation, empty, :absent)

IO.puts(
  "SOURCE_COHORT_PASS Elixir=#{System.version()} OTP=#{System.otp_release()} properties=10 no_new_processes=true optional_hosts_absent=true"
)
