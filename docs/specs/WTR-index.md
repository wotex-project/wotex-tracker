# WTR specification index

Start with the [software implementation sequence](../plans/software-implementation.md).
The WTR contracts describe required target behavior. Implementation readiness does not mean implementation, hardware qualification, interoperability, or conformance is complete.

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
- [WTR.14 Optional Nerves firmware and LiveView hosts](WTR.14-nerves-and-liveview-hosts.md)

[Primary source revisions](../provenance/primary-sources.md), [hardware qualification](../provenance/hardware-qualification.md), and future executed evidence are separate records.

The dated [ecosystem and hardware research](../provenance/ecosystem-research.md)
records dependency candidates, current-source caveats and patterns to borrow.
The [readiness review](../provenance/spec-readiness-review.md) records the audit
and its executable evidence without promoting implementation status.

- [Versioned specification catalogue](catalogue.yaml) — owning contracts, dependencies, status and baseline evidence
- [Architecture decision: headless core](../decisions/0001-headless-core.md)
- [Architecture decision: evidence before inference](../decisions/0002-evidence-before-inference.md)
- [Architecture decision: vendor independence](../decisions/0003-vendor-independent-hardware.md)
