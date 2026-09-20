# Pure fixture-to-Thing Description pipeline

The `Wotex.Tracker` facade admits observations, builds catalogues, resolves
profiles, imports through explicit decoders, and materialises Things. The
[Ruuvi guide](ruuvi.md) supplies the first imported fixture. Importing an unknown
or ambiguous observation succeeds with its original evidence, explicit unresolved
status and `decoded: nil`. It never runs a decoder or starts a scanner for that
input. Resolution, validation and materialisation do not confer authorization.

## Model and identity inputs

The archive contains the self-contained environmental-sensor and cellular
asset-tracker models under `priv/thing_models/`. The caller loads the applicable
file explicitly, admits its native JSON through `Model.new/3` and supplies the
exact ID/version pair referenced by the profile. Model construction calls
upstream `Wotex.ThingModel.from_map/2` with validation enabled and records full
content identity. No resolver, network fetch, inheritance engine or templating
language is included. `tm:ref`, composition links, placeholders, nested TM
directives and nonempty Action/Event sections return
`unsupported_model_feature` in this slice.

The model requires temperature and makes the other nine Properties optional.
A missing current sample does not remove a supported affordance. All Properties
are readable and have explicit units. Writable Properties and physical device
Events remain unsupported. Host delivery of committed Property values requires
the separate declaration below.

The generic cellular asset-tracker 1.0.0 model is selected by the configured
TAT140 profile; revision 1.1.0 is selected by ATC700 and adds a bounded integer
`batteryLevel` Property. Neither revision contains vendor or model names. Their
mandatory readable Properties include `position`, `motion` and
`batteryVoltage`. The aggregate position capability
uses `WGS84`; nested latitude/longitude use degrees, altitude and horizontal
accuracy use metres, and speed uses metres per second. Motion is dimensionless
and battery voltage uses volts. Latitude/longitude are required whenever a
position value is delivered; the other position members may be absent. A frame
without a fix does not change the model or imply a null coordinate pair.

Create explicit association evidence for the same observation and profile/decoder
revision, append it to the decoder's evidence through `EvidenceBundle.new/3`,
and obtain `Identity.new/3` from that bundle. The identity guide describes the
UUIDv4 pseudonym and complete association-claim contract. Neither a BLE address
nor the payload MAC becomes a public Thing identifier.

## Deployment inputs

`Deployment.new/2` requires atom-keyed `revision`, `title`, `forms`,
`security_definitions` and `security`. Forms are a native object keyed by exact
escaped affordance pointers. Every selected Property needs one to eight explicit
Forms. By default each Form declares `readproperty` (string or singleton list), an
absolute URI without embedded credentials or placeholders, and any security
references must resolve. Generic Form/security construction remains upstream.
Host Runtime/binding validation subsequently determines supported transport,
content type and actual operation behavior.

Security definitions and references are always explicit. There is no default
`nosec`, generated endpoint, credential lookup or deep merge of device metadata.
The supplied deployment revision becomes TD `version.instance`; the model's
version remains `version.model`. Hosts must issue and retain revision identities
when structure or deployment changes. Content digests bind the entire declaration,
including Forms for optional affordances that this invocation omits.

## Explicit host Property observation

A host implementing value delivery may supply optional `observation_evidence`,
a map from selected Property pointers to transport-evidence IDs. The default is
empty, preserving existing read-only output and deployment identities. For each
observed Property, its Forms must together declare `readproperty`,
`observeproperty` and `unobserveproperty`; streaming Forms use HTTP(S),
`contentType: "application/json"` and `subprotocol: "sse"`. Closing is a local
connection operation, not an invented device command.

Each referenced `Evidence` has kind `:transport`, confidence `:exact`, reason
`host_delivery_declaration`, the same source observations as the readable
capability, and precisely that capability's evidence IDs as parents. Its closed
claim object contains `schema: "wtr.delivery.v1"`, nonempty `provider` and
`revision`, `semantics: "committed-values"`, the exact `property` pointer,
`forms`, and `deployment_revision`. Profile/decoder revisions retain the same
bundle rules. After adding claims, rebuild `Identity` against the new bundle.

Materialisation checks this witness before setting `observable: true`. It rejects
missing witnesses, altered Forms/revisions, unrelated capability parents and a
model explicitly declaring `observable: false`. The decoder's readable capability
stays unchanged. A host declaration records its delivery responsibility; it does
not prove a physical-device subscription or a reachable endpoint. Real Runtime,
stream framing, authorization, replay and teardown require separate host tests.

## Materialisation inputs and result

Pass these explicit fields to `Wotex.Tracker.materialize/2`:

- `observation`, `catalogue`, `resolution`, and `decoded` from the import;
- `bundle` containing the original decoder evidence plus association evidence;
- `capabilities`, an admitted selection of that decoder's capabilities;
- `identity`, `model`, `mapping_revision`, and `deployment`.

Materialisation revalidates the decoder against its exact immutable observation
and catalogue without rerunning its callback. Generated claim identities and
support must remain consistent, all original decoded evidence must still resolve,
and selected capabilities must be present in the decoded result. Equal revision
labels alone cannot smuggle a different catalogue into an old decode.

Only optional Properties with exact `tm:optional` pointers may be omitted.
Mandatory missing support is `missing_capability`. Duplicate mapping destinations,
unknown destinations, incompatible units/operations and missing Forms fail.
Escaped Property names use upstream JSON Pointer semantics. The transform removes
consumed TM instructions/types, preserves applicable native extensions and other
types, and supplies the explicit instance title, ID, version, security and Forms.
The candidate enters `Wotex.ThingDescription.from_map/2` with validation enabled.

The result contains the validated TD, full private evidence bundle, provenance
and a versioned content identity covering the TD and all interpretation inputs.
Raw captures, protocol IDs, receiver IDs and association records are not copied
into the public TD. Publication policy and authorization remain host-owned.

## Executed scope

The fixed source-derived fixture TD is checked against an independent JSON
expectation. Structural validation and synthetic Forms do not prove a reachable
endpoint. Local signed-registry consumers run the archive in production without
path dependency switches, optional hosts or newly created processes. Public Hex
release availability and actual Runtime/software-peer interaction are separate
gates. See [implementation evidence](../evidence/implementation.md).
