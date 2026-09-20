# WTR specification index

Start with the [software implementation sequence](../plans/software-implementation.md).
The WTR contracts describe required target behavior. Implementation readiness does not mean implementation, hardware qualification, interoperability, or conformance is complete.

## Completion axes

Every WTR contract and catalogue delivery target reports completion on four
independent axes defined normatively by WTR.12:

- **development** — repository-owned implementation that can be written and
  verified locally;
- **local acceptance** — executable tests using fixtures, deterministic peers,
  simulators, emulators, QEMU, containers and loopback services;
- **qualification** — real hardware, radio, carrier, operating-system device or
  external-provider execution; and
- **distribution** — registry/account/signing/upload/review work performed with
  the required external authority.

An unavailable device, SIM, carrier, provider credential, Apple membership or
store account can leave qualification or distribution unpassed. It MUST NOT mark
locally executable development as blocked. All code paths, adapters, failure
handling, simulators, test doubles, packaging and automated acceptance that can
run without the external prerequisite MUST be completed first. Conversely, a
simulator, screenshot, local APNs peer, unsigned iOS build or QEMU boot never
promotes the corresponding physical/provider/distribution axis.

The language policy in WTR.13 also applies to every contract. For this greenfield
product, Zig is the default language for bounded standalone native code and
generated C-ABI surfaces where it is demonstrably safer and simpler. Platform
framework integration retains the platform's established language when replacing
it with manual runtime calls would weaken type, ownership or lifecycle safety.

- [WTR.00 Library and application boundary](WTR.00-library-contract.md)
- [WTR.01 Observation, identity and evidence model](WTR.01-observation-identity-evidence.md)
- [WTR.02 Discovery, fingerprinting and capability resolution](WTR.02-discovery-and-capabilities.md)
- [WTR.03 Device profiles, decoders and protocol adapters](WTR.03-device-profiles-and-adapters.md)
- [WTR.04 Thing Model and Thing Description materialisation](WTR.04-thing-materialisation.md)
- [WTR.05 Tracking state, positioning and deterministic policy](WTR.05-tracking-and-policy.md)
- [WTR.06 Transport selection, store-and-forward and fallback](WTR.06-transport-policy.md)
- [WTR.07 Headless service, machine interfaces and UI boundary](WTR.07-headless-interfaces.md)
- [WTR.08 Security, privacy, anti-stalking and physical actions](WTR.08-security-and-privacy.md)
- [WTR.09 Hardware qualification and vendor-independence](WTR.09-hardware-qualification.md)
- [WTR.10 WoTEx ecosystem integration](WTR.10-wotex-integration.md)
- [WTR.11 Optional Refpath AI integration](WTR.11-refpath-integration.md)
- [WTR.12 Executable evidence, fixtures and PoC graduation](WTR.12-evidence-and-graduation.md)
- [WTR.13 Elixir/OTP implementation and verification floor](WTR.13-elixir-otp-and-verification.md)
- [WTR.14 Nerves firmware and Pi control panel](WTR.14-nerves-and-liveview-hosts.md)
- [WTR.15 Tracking application and mobile companion](WTR.15-product-and-mobile-applications.md)
- [WTR.16 Metrics, prompted analytics and dynamic graphs](WTR.16-metrics-and-prompted-analytics.md)

The complete application, service distribution, Pi control panel, iPhone companion
and interactive/prompted analytics are required deliverables. Their hosts remain
optional installations for library consumers. Required delivery targets and
unexecuted evidence are recorded in the catalogue; a framework or funding gap
cannot waive their gates. LoRaWAN and private Refpath remain optional integrations.

[Primary source revisions](../provenance/primary-sources.md), [hardware qualification](../provenance/hardware-qualification.md), and future executed evidence are separate records.

The dated [ecosystem and hardware research](../provenance/ecosystem-research.md)
records dependency candidates, current-source caveats and patterns to borrow.
The [readiness review](../provenance/spec-readiness-review.md) records the audit
and its executable evidence without promoting implementation status.

- [Versioned specification catalogue](catalogue.yaml) — owning contracts, dependencies, status and baseline evidence
- [Architecture decision: headless core](../decisions/0001-headless-core.md)
- [Architecture decision: evidence before inference](../decisions/0002-evidence-before-inference.md)
- [Architecture decision: vendor independence](../decisions/0003-vendor-independent-hardware.md)
