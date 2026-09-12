# WTR.04 Thing Model and Thing Description materialisation

## Status

Accepted target contract. No implementation claim.

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

The candidate MUST be parsed and validated by `wotex` before publication or runtime use.

## Capability-to-affordance mapping

Evidence-backed readable state becomes Properties. Asynchronous device facts become Events when the underlying interaction semantics justify events. Mutating device operations become Actions or writable Properties according to the relevant WoT model and binding semantics.

A brochure feature MUST NOT become an affordance unless the qualified profile proves how it is observed or invoked.

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

## Directory

Once validated and authorized for publication, a TD MAY be registered with `wotex_directory`. Discovery observations and unresolved candidates are not Thing Descriptions and MUST NOT be published to the Directory as if they were trusted Things.

## Historical stability

Changing a profile or Thing Model MUST NOT retroactively reinterpret stored raw observations without an explicit replay/migration operation that records the new profile/model revision. Materialised TD revisions SHOULD retain links to the evidence/profile revision that produced them.
