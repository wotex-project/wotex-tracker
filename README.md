# Wotex Tracker

**Deterministic physical-device discovery, capability evidence, and WoT Thing materialisation for Elixir.**

`wotex_tracker` is a headless-first WoT intermediary and reference application for turning heterogeneous physical trackers and sensors into validated W3C Web of Things Thing Descriptions.

The project is intentionally hardware- and transport-agnostic. A physical device may first appear as a BLE advertisement, a cellular tracker connection, a LoRaWAN uplink, MQTT data, HTTP data, or another bounded ingress. Tracker preserves the raw observation as evidence, identifies a versioned device profile deterministically, decodes only what that profile proves, materialises an instance Thing Description from a Thing Model, and exposes the resulting Thing through ordinary WoT interfaces.

```text
physical device
      |
      v
bounded observation
      |
      v
fingerprint -> device profile -> decoder -> capability evidence
                                      |
                                      v
                              Thing Model + identity
                                      |
                                      v
                              Thing Description
                                      |
                         +------------+------------+
                         |                         |
                    Wotex Runtime             Directory
                         |
                    HTTP / MQTT / ...
```

## Status

This repository starts from **accepted target specifications**. Specification presence, fixtures, examples, or catalogue entries do not imply implementation, hardware qualification, interoperability, or W3C conformance. Executed evidence is tracked separately from target contracts.

Start with the [WTR specification index](docs/specs/WTR-index.md) and the [software implementation sequence](docs/plans/software-implementation.md).

## Design rules

- **Headless first.** The reusable service and machine interfaces are authoritative. CLIs, mobile apps, Phoenix/Svelte UIs, and fleet products are consumers.
- **Evidence before inference.** Device identity and capabilities come from deterministic protocol evidence, not AI guesses.
- **No vendor-cloud dependency.** A supported hardware profile must have a documented path to infrastructure controlled by the operator. Vendor SaaS may be optional but never mandatory.
- **Transport is not semantics.** BLE, LTE-M/NB-IoT/Cat-1, LoRaWAN, Wi-Fi, MQTT, HTTP, and vendor wire protocols are ingress or interaction mechanisms. Applications consume WoT Properties, Actions, and Events.
- **LoRaWAN is optional.** A device profile may use it, but the architecture does not require it.
- **AI is optional.** Refpath may reason over validated Things and propose governed actions, but tracking, discovery, decoding, rules, alarms, and Thing materialisation must work with no AI engine present.
- **Safe by default.** Unknown devices stay unknown. Ambiguous matches are not auto-admitted. Physical Actions require stronger evidence and authorization than read-only Properties.

## Initial proof matrix

The first profiles are intended to prove different topologies rather than one preferred vendor:

- **RuuviTag** — passive BLE advertisement discovery and environmental sensing using an openly documented wire format.
- **Teltonika TAT140** — finished rugged cellular asset tracker sending directly to an operator-controlled server.
- **Teltonika ATC700** — compact rechargeable cellular tracker using the same semantic asset-tracker model through a different profile.
- **LoRaWAN** — optional later profile/ingress lane, only for hardware and network paths that pass the project's no-vendor-lock gate.

Hardware names in specifications are qualification targets, not architectural dependencies.

## WoTEx boundaries

`wotex_tracker` consumes the WoTEx ecosystem rather than replacing it:

- `wotex` owns TD/TM/DataSchema/Form values and validation.
- `wotex_runtime` owns portable ConsumedThing/ExposedThing interaction planning and ports.
- `wotex_directory` owns Thing Description Directory semantics.
- protocol bindings such as HTTP and MQTT own WoT Form-to-protocol mapping.
- `wotex_continuum` may carry host-neutral observations/actions across edge/cloud boundaries.
- `wotex_nx` may add deterministic numerical analysis.
- `wotex_lab` remains the experimental/qualification laboratory.
- Refpath is an optional AI/agent consumer of validated WoT affordances.

Core WoTEx packages must never depend on `wotex_tracker`.

## License

Apache-2.0. See `LICENSE` once the repository foundation is completed.