# WTR.08 Security, privacy, anti-stalking and physical actions

## Status

Accepted target contract. The maintained
[abuse analysis](../security/abuse-analysis.md) and unauthenticated shared Safety
page state the product's dual-use risks, implemented software controls, response
guidance and unpassed production gates. A hardware-backed visible tracking-state
control, unauthorized-association detection, physical permission-denial evidence
and complete device acceptance remain open; no production anti-stalking claim is
made.

## Threat model

Tracker deals with physical location and therefore treats privacy abuse as a first-class security concern. Threats include BLE spoofing/replay, cloned identifiers, malicious advertisements, hostile scanners, stolen LoRaWAN/cellular credentials, forged tracker records, replayed historical positions, unauthorized physical Actions, vendor-cloud exfiltration, compromised gateways, and use of the software for covert stalking.

## Data minimization

Raw BLE addresses, IMEIs, IMSIs, ICCIDs, phone numbers, LoRaWAN identifiers/keys and other stable identifiers are sensitive. Public Thing IDs and ordinary telemetry MUST use pseudonymous identifiers unless a privileged operator explicitly requests underlying evidence.

Location history MUST have explicit retention policy. Debug logs MUST NOT contain credentials or unbounded raw packets by default.

## BLE

BLE identity confidence MUST account for address randomization. Manufacturer/service payloads are untrusted input. Replayable advertisement identifiers MUST NOT be treated as cryptographic identity.

Active GATT probes require explicit policy and finite deadlines. Pairing/bonding material remains in caller-owned credential custody.

## LoRaWAN

Network/application keys MUST never appear in TDs, profile files committed to source, public evidence fixtures, telemetry events or errors. Frame counters and network-server evidence SHOULD be used to reject replay according to LoRaWAN semantics.

## Cellular

SIM/eSIM credentials and APN credentials remain outside TDs and profile metadata. Direct device protocols MUST authenticate or otherwise bind a connection to enrolled identity as strongly as the protocol allows. Source IP alone is insufficient identity.

## Observation integrity

Where hardware supports signed telemetry or secure-element identity, profiles SHOULD preserve and verify that evidence. When protocols lack cryptographic authenticity, the lower trust level MUST remain visible rather than being upgraded by software inference.

## Physical actions

Read-only sensing and physical control have different risk. Actions such as immobilize, unlock, alarm/siren, firmware update, configuration change or reporting-policy change require explicit authorization. High-impact actions SHOULD support human approval, freshness requirements and replay protection.

An AI engine may propose a physical Action but MUST NOT bypass the same authorization/policy boundary used by human/API callers.

The service's first executable Action boundary retains a caller-scoped intent
only after current `interact` authorization, exact Thing-generation matching and
closed primitive input admission. Its optional dispatcher rechecks current
grants, durable revocation and Thing identity immediately before claim. Claim is
durably `unknown` before one WoTEx Runtime transport call; timeout, crash and
ambiguous transport completion are never retried automatically. Selection or
credential failure is distinct from transport uncertainty, and protocol
acceptance never becomes physical-effect success. Packaged profiles still
declare no Action, so this is synthetic boundary evidence rather than hardware
qualification.

## Anti-stalking

The application MUST include an abuse analysis before claiming production
readiness. Personal tracking MUST provide owner enrollment, visible control of
tracking state, access audit, credential revocation and mechanisms appropriate
to the hardware for detecting unauthorized tracker association. Refusing location,
notification or Bluetooth permission must not be bypassed through another bridge.

The project MUST NOT market covert surveillance as a feature. Generic OSS cannot guarantee platform-level unwanted-tracker detection comparable to phone-vendor ecosystems; documentation must state this limitation.

## Supply chain

Profiles record firmware/protocol revisions where available. Dependencies, firmware blobs and native components require provenance. Mandatory opaque vendor cloud components fail hardware qualification under WTR.09.

## Library input and execution boundary

Apply WTR.01 admission to every untrusted envelope, including JSON object keys, UTF-8, bytes, nested collections and provenance. No input-created atoms, dynamic module lookup from wire names, evaluated profile source, or Erlang external-term deserialization is accepted. Trusted callback configuration is application code, not sandboxed device content; validate its results at the declared seam. Do not broadly suppress internal defects.

Deployment Forms, paths and executables are explicit operator inputs, never inferred from device-supplied addresses or URLs. Pure matching/materialisation performs no URL retrieval, remote model/context fetch or filesystem access. A host that accepts configurable destinations must enforce its authorization and routing policy before any request, including redirects. File/native adapters must define traversal, symlink, executable-identity and bounded-output checks before being admitted. Lexical containment and digests alone neither authenticate a device nor isolate hostile concurrent filesystem writers.

Raw evidence is private, bounded and subject to retention. Public serialization, structured errors, logs and telemetry must use reviewed projections that exclude credentials and stable private identifiers, including nested callback/provenance details. Do not use identifiers, payloads or arbitrary profile strings as unbounded metric labels. Tests exercise successful and rejected paths, not just logger formatting in isolation.

## Application and analytics boundary

WTR.07 authorization applies equally to HTTP, SSE, CLI and local service calls.
WTR.15 adds native WebView origin/session binding, secure credential custody and
mobile lifecycle requirements. Possessing the Pi touch panel, a loopback URL or
a cached dashboard is not implicit authorization. Revocation must stop new reads,
mutations and deliveries on existing sessions; reconnect rechecks authority.

The host isolates caches, saved queries, exports, push tokens and pending work by
server/principal/scope. Switching accounts or infrastructure cannot retain access
to the previous scope. Define deletion across primary storage, cache, export and
backup retention honestly; remote revocation cannot erase an already offline
copy instantly. Revalidate at reconnect and apply local expiry/purge policy.

Model translation and investigations use WTR.16's bounded data contract. Neither
prompt instructions nor raw device text can choose executable tools, widen data
scope, install code or bypass physical-action policy. Runtime introspection is
privileged operator access, separate from ordinary user analytics. Egress of
location or raw evidence needs explicit disclosure policy, independently of
permission to render a graph locally.
