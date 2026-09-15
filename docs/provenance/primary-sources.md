# Primary source provenance

This records reviewed contracts and source identities, not package availability, clean-build compatibility, hardware qualification or conformance. Local source inspection is the authority for the repository rows; commit links do not assert remote publication.

Baseline date: 2026-09-12.

See the [ecosystem research](ecosystem-research.md) for dated public release
candidates and adoption decisions. Local source pins and public package releases
are different evidence; neither implies a passing Tracker consumer build.

## W3C Web of Things

The design is intentionally aligned with the WoTEx ecosystem's existing standards baseline rather than creating tracker-specific alternatives. Relevant W3C families include Thing Description 1.1, Thing Model semantics, WoT Discovery, WoT Architecture, WoT Security and Privacy guidance, and binding-template/binding specifications used by installed WoTEx packages.

Exact normative revisions used by code MUST be pinned in the owning upstream WoTEx package and referenced here rather than duplicated. Tracker consumes those contracts.

## WoTEx repositories inspected

| Repository | Source revision | Relevant boundary |
|---|---|---|
| `wotex` | [`070d97eb233b69c67af74f29e9f4d2a1f2ac6d25`](https://github.com/wotex-project/wotex/blob/070d97eb233b69c67af74f29e9f4d2a1f2ac6d25/lib/wotex/thing_model.ex) | TM/TD/JSON constructors; model instantiation excluded |
| `wotex-runtime` | [`d2c526b2ab89aff62ff031ceba406a366084562c`](https://github.com/wotex-project/wotex-runtime/blob/d2c526b2ab89aff62ff031ceba406a366084562c/lib/wotex/runtime/consumed_thing.ex) | interaction plans, explicit ports and child specifications |
| `wotex-binding-http` | [`f6ee5c85726b2d95c178d9e5ec080a76333d46ae`](https://github.com/wotex-project/wotex-binding-http/blob/f6ee5c85726b2d95c178d9e5ec080a76333d46ae/README.md) | HTTP/SSE mapping with caller-supplied client |
| `wotex-binding-mqtt` | [`14c8fd2160a488aaad650a6f5e41314db3619add`](https://github.com/wotex-project/wotex-binding-mqtt/blob/14c8fd2160a488aaad650a6f5e41314db3619add/README.md) | MQTT mapping with caller-supplied client |
| `wotex-ble` | [`83fd720aff76ff564d21592cf14bf33bef49a434`](https://github.com/wotex-project/wotex-ble/blob/83fd720aff76ff564d21592cf14bf33bef49a434/README.md) | GATT/session APIs; native target separate from current backend |
| `wotex-directory` | [`418a1af36b13a60ec89452021dc139e94f599ac2`](https://github.com/wotex-project/wotex-directory/blob/418a1af36b13a60ec89452021dc139e94f599ac2/lib/wotex/directory/repository.ex) | conditional mutations and page snapshot contract |
| `wotex-continuum` | [`032eab5b1ae125e67e35fc51a4ba6d8337e4c235`](https://github.com/wotex-project/wotex-continuum/blob/032eab5b1ae125e67e35fc51a4ba6d8337e4c235/README.md) | inert exchange values, no transport |
| `wotex-nx` | [`e7466cf4f9fa8a501b10d55ac36e365d4fb1f755`](https://github.com/wotex-project/wotex-nx/blob/e7466cf4f9fa8a501b10d55ac36e365d4fb1f755/README.md) | numerical conversion, no model/fusion execution |
| `wotex-conformance` | [`84c5569b65eacccb21e3514e89fd283680c33394`](https://github.com/wotex-project/wotex-conformance/blob/84c5569b65eacccb21e3514e89fd283680c33394/CLAUDE.md) | external artifact/corpus evidence, no subject compile dependency |
| `wotex-bacnet` | [`a7610c71f747f86a81c56400a09b97e3101704af`](https://github.com/wotex-project/wotex-bacnet/blob/a7610c71f747f86a81c56400a09b97e3101704af/CLAUDE.md) | BACnet protocol owner; explicit runtime acquisition |
| `wotex-coap` | [`ac49c68a0d6f9f289b31dca8f4577fed4bdaa6b1`](https://github.com/wotex-project/wotex-coap/blob/ac49c68a0d6f9f289b31dca8f4577fed4bdaa6b1/CLAUDE.md) | CoAP protocol owner; explicit runtime acquisition |
| `wotex-thread` | [`fd0cad3fd423489b3bb106f478dac0fdbfe14bcc`](https://github.com/wotex-project/wotex-thread/blob/fd0cad3fd423489b3bb106f478dac0fdbfe14bcc/CLAUDE.md) | Thread protocol owner; explicit runtime acquisition |
| `wotex-matter` | [`abaf77f0f6f07105ddcd7bbd83fb01b1a7522394`](https://github.com/wotex-project/wotex-matter/blob/abaf77f0f6f07105ddcd7bbd83fb01b1a7522394/CLAUDE.md) | Matter protocol owner; explicit runtime acquisition |
| `wotex-modbus` | [`be4e866795daed73e768bc413b6c0229644b6b1a`](https://github.com/wotex-project/wotex-modbus/blob/be4e866795daed73e768bc413b6c0229644b6b1a/CLAUDE.md) | Modbus protocol owner; explicit runtime acquisition |
| `wotex-opcua` | [`66c1a789cf884d473c82b371bc2f7926ab52cf91`](https://github.com/wotex-project/wotex-opcua/blob/66c1a789cf884d473c82b371bc2f7926ab52cf91/CLAUDE.md) | OPC UA protocol owner; explicit runtime acquisition |
| `wotex-lab` | [`73161df81921987b8d597db01c30c50c99d06e53`](https://github.com/wotex-project/wotex-lab/blob/73161df81921987b8d597db01c30c50c99d06e53/README.md) | optional experimental consumer, excluded from Tracker dependency plan |

Tracker specifications intentionally follow the WoTEx convention of numbered target contracts, an index, a machine-readable catalogue, provenance, decisions and an implementation plan. Implementation evidence remains separate.

All inspected root Mix libraries declare Elixir `~> 1.18`; inspected CI lanes select Elixir 1.20 / OTP 29. Declarations alone do not prove all allowed runtime combinations. Tracker has no Mix requirement or executed support matrix yet. Native protocol prerequisites and optional Nx requirements must be qualified independently.

All 15 sibling libraries excluding Lab have no first-party `mod:` application callback in their root Mix declarations. Source inspection found no ambient `Application.get_env/fetch_env/compile_env` configuration or fixed registered session singleton. Explicit session processes are permitted. Calls clearing child-process environment variables are not global library configuration. CoAP's explicit DTLS path starts OTP SSL; this is not automatic network work on loading CoAP. These are focused ownership observations, not complete sibling production audits.

## Elixir and OTP design references

- [Let libraries be libraries](https://jola.dev/posts/let-libraries-be-libraries), Johanna Larsson, 7 July 2026: caller-controlled configuration and supervision, including independent instances. Libraries may expose supervised components without application-owned singletons.
- [Elixir design anti-patterns](https://elixir.hexdocs.pm/design-anti-patterns.html), observed as 1.20.4: explicit library inputs and consumer supervision. Reading newer guidelines does not raise Tracker's runtime floor.
- [Elixir 1.18 GenServer](https://hexdocs.pm/elixir/1.18/GenServer.html): child specifications, registration, monitoring and timeout semantics.
- [OTP efficiency guide: processes](https://www.erlang.org/doc/system/eff_guide_processes.html), observed as OTP 29.0.6: process/ETS copying and measurement before tuning.
- [Jason 1.4.4 source documentation](https://raw.githubusercontent.com/michalmuskala/jason/v1.4.4/lib/jason.ex): string keys, ordered objects, retention and iodata. The inspected core lockfile selects Jason 1.4.5 and ex_json_schema 0.11.5. Tracker consumes `Wotex.JSON` admission rather than a competing parser or default decoding that could discard duplicate members.

## Device protocol research

[Ruuvi RAWv2 format 5](https://docs.ruuvi.com/communication/bluetooth-advertisements/data-format-5-rawv2), read 2026-09-12, supplies frame layout and valid/extreme/unavailable vectors. An unavailable payload is still a complete frame; humidity above 100% is representable but anomalous. A movement counter alone is not a movement boolean. Before committing decoder fixtures, record the source snapshot/digest, permissions, transformations and profile revision. This living page is not firmware qualification; no real capture was obtained in this review.

Teltonika models and LoRaWAN remain research targets in the [hardware ledger](hardware-qualification.md). No new hardware, radio, operator, regulatory or direct-endpoint compatibility claim is made here.

## Position geometry

- [NGA World Geodetic System 1984](https://earth-info.nga.mil/?action=wgs84&dir=wgs84),
  read 2026-09-16: official defining semi-major axis 6,378,137.0 m and inverse
  flattening 298.257223563. Tracker derives the authalic radius documented in the
  [geofence guide](../guides/geofences.md) and pins its own bounded approximation;
  citing WGS 84 parameters does not turn that approximation into an NGA geodesic
  implementation or survey/conformance claim.
- [GeographicLib geocentric reference](https://geographiclib.sourceforge.io/2009-03/classGeographicLib_1_1Geocentric.html),
  read 2026-09-16: distinguishes WGS 84 geodetic latitude/longitude/height from
  Earth-centred Cartesian coordinates. Tracker does not import GeographicLib or
  claim its accuracy; the reference is retained to keep coordinate-system terms
  precise.

## Refpath

Refpath remains an optional downstream consumer under WTR.11. Its private implementation and compatibility were not verified in this review. Tracker acceptance must work with it absent.

Because Refpath is not an OSS dependency of Tracker, no private Refpath source is copied into this repository.

## Updating

Any standards claim that materially changes matching, TD materialisation, security, discovery or binding semantics requires a dated provenance update and review of the owning WTR contract.
