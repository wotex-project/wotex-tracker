# WTR.08 Security, privacy, anti-stalking and physical actions

## Status

Accepted target contract. No implementation claim.

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

## Anti-stalking

The reference application MUST include an abuse analysis before claiming production readiness. Deployments intended for personal tracking SHOULD provide owner enrollment, visible control of tracking state, access audit, credential revocation, and mechanisms appropriate to the hardware for detecting unauthorized tracker association.

The project MUST NOT market covert surveillance as a feature. Generic OSS cannot guarantee platform-level unwanted-tracker detection comparable to phone-vendor ecosystems; documentation must state this limitation.

## Supply chain

Profiles record firmware/protocol revisions where available. Dependencies, firmware blobs and native components require provenance. Mandatory opaque vendor cloud components fail hardware qualification under WTR.09.
