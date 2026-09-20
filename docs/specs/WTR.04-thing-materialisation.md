# WTR.04 Thing Model and Thing Description materialisation

## Status

Implemented for the first pure software milestone: the packaged environmental
sensor and cellular asset-tracker models, explicit evidence/capability mapping,
deployment-owned Property/Action Forms and security, upstream TM/TD validation,
deterministic canonical output and the failure cases below are covered by
executable tests. A synthetic Action is materialised only from an explicit
decoder capability, profile mapping and invocation Form; no packaged profile or
execution adapter claims a physical Action.
Synthetic Forms do not prove endpoint reachability, installed Runtime bindings,
publication authorization or physical hardware. See the
[materialisation guide](../guides/materialisation.md) and
[executed evidence](../evidence/implementation.md#wtr04-materialisation-and-public-facade--2026-09-15).

## Principle

Tracker does not invent a new semantic schema for every hardware SKU. Qualified device profiles map evidence to reusable W3C WoT Thing Models, then materialise instance Thing Descriptions with the forms actually available for that device deployment.

## Thing Models

The initial semantic model family SHOULD cover reusable roles such as:

- environmental sensor;
- passive asset tag;
- motion/tamper sensor;
- position-capable tracker;
- cellular asset tracker;
- multi-transport tracker; and
- gateway/scanner where exposing the gateway itself as a Thing is useful.

A vendor model may extend a generic model when it has genuinely distinct affordances. Vendor names MUST NOT be embedded in generic property names.

The first milestone implements one self-contained environmental-sensor model and its explicit Ruuvi mapping. The wider model family above is later scope justified by implemented profiles; it is not a requirement to build an inheritance engine now.

## Materialisation inputs

TD materialisation consumes only explicit inputs:

```text
validated Thing Model
+ resolved device profile/version
+ stable Thing identity
+ capability evidence
+ deployment-specific endpoints/forms
+ security scheme references
+ explicit metadata/provenance
= candidate Thing Description
```

The native candidate map MUST enter `Wotex.ThingDescription.from_map/2` with validation enabled before publication or Runtime use. `Wotex.ThingModel.from_map/2` validates the input model; upstream provides no instantiation operation. Do not serialize an already admitted map merely to parse it again, bypass validation, or use a forged upstream struct as validation evidence.

## First materialisation algorithm

1. Validate the immutable model, evidence bundle, explicit pseudonymous identity and deployment inputs under their bounds. Require the selected profile's exact model/mapping revision and complete association evidence. Unknown, candidate-only or ambiguous resolution cannot materialise a Thing.
2. Admit only the implemented self-contained model subset. Cross-model composition, `tm:ref` resolution, placeholder substitution and Event materialisation are unsupported in this milestone and return `:unsupported_model_feature`; they are not fetched or silently ignored. A valid upstream TM can still be unsupported by this materialiser. Unknown JSON extensions are preserved when valid for the resulting TD, never reinterpreted as executable instructions.
3. Select evidence-backed affordances using an explicit mapping. Only optional affordances declared by exact `tm:optional` pointers may be omitted. Missing evidence for a mandatory affordance is `:missing_capability`; no unsupported affordance may survive merely to satisfy validation. Resolve escaped pointer names using upstream JSON pointer semantics.
4. Construct a new TD map: remove the model's `tm:ThingModel` type and consumed `tm:optional` instruction, preserve other applicable types/extensions, use the supplied instance ID/title, and apply only the allowed deployment fields. Model identity remains provenance; it is not reused as physical Thing identity. Do not deep-merge arbitrary device input into the TD or discard fields by an unreviewed blanket filter.
5. Require explicit security definitions/references and at least one appropriate deployment Form for every selected affordance. No default `nosec`, invented endpoint, placeholder URL or inferred credentials. Validate exact affordance/operation mapping, read/write/event semantics and duplicate mapping targets. Observation addressing does not supply deployment URLs.
6. Validate the candidate through upstream core and return the validated TD. The evidence bundle remains available to the caller with its model/profile/deployment revisions; public TD provenance must exclude private identifiers and raw payloads. Any failed stage returns a typed error without publishing, writing state or executing a Form.

Tests must cover optional omission, missing mandatory capability, escaped affordance names, unsupported model features, duplicate mapping destinations, mismatched revisions, unresolved security, missing Forms, exact Action invocation Forms, preserved native extension values and type-strict deterministic output. A fixed model/evidence/deployment bundle must yield identical upstream canonical bytes independent of map insertion or catalogue order. Canonical encoding here means the upstream package's declared format, not general JSON canonicalization compliance.

## Capability-to-affordance mapping

Evidence-backed readable state becomes Properties. Asynchronous device facts become Events when the underlying interaction semantics justify events. Mutating device operations become Actions or writable Properties according to the relevant WoT model and binding semantics.

A brochure feature MUST NOT become an affordance unless the qualified profile proves how it is observed or invoked.

The decoder's optional closed Action-name list creates a capability claim with
`interaction: "action"`, `operations: ["invoke"]` and no unit. Materialisation
requires that exact capability, a profile mapping to `/actions/{name}` and a
deployment Form declaring only `invokeaction`. This is structural and provenance
evidence. Authorization, input admission, durable intent, dispatch and effect
evidence belong to later service/device boundaries.

Readable does not imply observable, and receiving advertisements does not itself justify an Event subscription. Capability support remains stable across a missing sample. An unavailable measurement must follow the declared host/schema error or nullable-value contract without mutating the TD on every packet.

Typical tracker properties include:

- `position` with latitude/longitude/accuracy when available;
- `positionSource` or equivalent provenance metadata;
- `motion`;
- `batteryLevel`/`batteryVoltage`;
- `temperature`, `humidity`, pressure or acceleration where supported;
- `tamper`;
- `lastObservedAt`;
- `connectivity` as derived state only when its derivation is explicit; and
- reporting/configuration state where safely readable.

Typical events include movement, tamper, geofence transition, low battery, sensor threshold and connectivity degradation. Alarm truth is produced by deterministic policy, not AI.

## Forms

Forms represent usable interaction endpoints, not radio marketing claims. For example, a cellular tracker may upload AVL records to Tracker while the materialised Thing is exposed outward through HTTP or MQTT. The TD does not need to pretend LTE is directly consumed by an application.

Multiple forms MAY be materialised for the same affordance when multiple qualified interaction paths exist. Selection is delegated to `wotex_runtime` and installed binding profiles.

Pure materialisation proves structural validity and declared endpoint completeness, not endpoint reachability, installed transport support, enrollment authority or successful observation. The fixture milestone uses explicit synthetic deployment Forms and must be labelled accordingly. Later host acceptance checks real Runtime selection and interaction through the chosen binding/client. Unsupported schemes/media/operations fail at that boundary rather than falling back to another transport.

## Directory

Once validated and authorized for publication, a TD MAY be registered with `wotex_directory`. Discovery observations and unresolved candidates are not Thing Descriptions and MUST NOT be published to the Directory as if they were trusted Things.

## Historical stability

Changing a profile or Thing Model MUST NOT retroactively reinterpret stored raw observations without an explicit replay/migration operation that records the new profile/model revision. Materialised TD revisions SHOULD retain links to the evidence/profile revision that produced them.
