# Abuse analysis and anti-stalking release gate

## Decision

WoTEx Tracker is dual-use location software. It is not production-ready for
personal tracking until the deployment's actual hardware, phone application and
operating procedures demonstrate the remaining controls in this analysis. The
software controls below reduce abuse risk; they do not provide a phone-vendor-
scale unwanted-tracker detection network and must not be marketed as one.

This analysis covers the repository's shared application, service, mobile shell
and planned Pi/hardware integrations. It must be reviewed again when a physical
tracker, radio path, native permission, physical Action or external destination
is added or materially changed.

## Protected people, data and capabilities

The safety boundary protects:

- a person who carries, rides, owns or is near a tracked asset;
- operators and readers whose credentials can reveal retained locations;
- raw radio, cellular, subscriber, receiver and hardware identifiers;
- retained position, motion, trip, owner-presence and alert history;
- association, arming and protection-policy state; and
- any future physical Action such as alarm, immobilization, unlock, firmware or
  reporting-policy changes.

Possession of a device, phone, Pi display, cached page, loopback URL, observation
or replayable radio identifier is not proof of ownership or authorization.

## Abuse cases and current controls

| Abuse case | Implemented software controls | Residual risk and required gate |
|---|---|---|
| A tracker is attached to a person, bicycle, vehicle or bag without consent. | Enrollment and later reassociation require an administrator grant, a current generation and explicit operator confirmation. The shared Safety page states that confirmation is not hardware authentication. | No qualified hardware-specific unauthorized-association detector exists. Physical discovery, labelling, audible/visible indications and phone-vendor unwanted-tracker behavior require selected-hardware evidence. |
| A replayed or cloned identifier is enrolled as the wrong device. | Radio and protocol input remains untrusted evidence; public identity is pseudonymous; association evidence records the operator decision and exact observation/profile revisions. | Replayable BLE advertisements and other unsigned protocols cannot establish cryptographic identity. Qualification must document the exact trust level, reset/provisioning behavior and any signed or secure-element evidence. |
| A stolen credential reads history or changes protection state. | Credentials are hashed in private host configuration, grants are scoped, revocation is durable, current authority is rechecked, and successful decisions enter a bounded access journal. Existing streams and mobile lifecycle transitions recheck authority. | Offline exports and caches cannot receive instantaneous remote revocation. Mobile acceptance must prove expiry, sign-out/account-switch purge and reconnect invalidation on a real signed installation. |
| A privileged operator conceals access or erases evidence. | Readers cannot manage credentials or deletion. Administrators can inspect credential state and the bounded successful-access journal. Managed data deletion preserves revocations and that journal, records a public marker/cause and uses a recoverable receipt for manual deletion. | A host administrator controls the machine and backups. External immutable audit, organizational separation of duties and evidence-preservation procedure are deployment responsibilities. |
| Location data survives longer or travels farther than disclosed. | Public projections omit stable private identifiers. Managed scope counts, deletion limits and configured inactivity retention are visible. Prompt adapters receive a closed disclosed schema rather than automatic raw location/evidence. | Backups, offline exports and already-remote publications remain operator-managed. Every external destination needs an explicit retention, authorization and deletion procedure. |
| A bridge bypasses denied Bluetooth, location or notification permission. | Native bridges use closed messages and capability-bound sessions; browser content cannot choose modules, tools or arbitrary URLs. No software test claims that an OS permission was granted. | Real-device tests must deny each permission and prove that no other bridge, cached grant or background path performs the denied capability. This is unpassed. |
| A rule, model or user triggers a dangerous physical Action. | Current arming is explicitly a service fact and states that it does not contact hardware. Prompted analytics can only propose closed queries. The service exposes no generic physical-Action execution path. | Any future Action needs separate authorization, freshness, approval, replay protection, device acknowledgement and historical-replay suppression before it is enabled. |
| A compromised gateway, scanner or vendor service forges or exfiltrates data. | Inputs are bounded and validated; public errors, logs and telemetry use reviewed projections; mandatory vendor cloud is a hardware-qualification failure. | Physical ingress authentication, network isolation and operator-controlled endpoints must be proved for the selected hardware and deployment. |

## User-visible safety contract

`/safety` is deliberately available without an authenticated account. It states
the unwanted-tracker limitation, distinguishes operator confirmation from device
authentication, links authenticated users to access/privacy/enrollment controls,
and gives a response checklist. It performs no service query and never presents
its availability as evidence that a tracker was or was not detected.

The project must not use terms such as *safe*, *trusted*, *owner verified* or
*anti-stalking protection* for a device merely because an enrollment record,
radio observation or software alert exists. Screens must keep unknown, missing,
unavailable and negative evidence distinct.

## Response checklist

When unauthorized tracking is suspected:

1. do not use this application as proof that no tracker is present;
2. use the unwanted-tracker and safety guidance supplied by the phone platform
   and relevant hardware manufacturer;
3. prioritize immediate personal safety and contact local emergency services
   when appropriate;
4. when safe, preserve physical identifiers and access/audit evidence needed for
   an investigation before deletion or reset;
5. revoke unexpected credentials, inspect the successful-access journal and
   remove unauthorized associations; and
6. separately locate and remove backups, exports and remote copies when deletion
   is required.

## Unpassed production gates

The following remain blockers rather than documentation exceptions:

- select and qualify the portable tracker and its exact unauthorized-association
  detection/indication mechanism;
- prove provisioning, ownership transfer, reset and recovery with the real device;
- define and prove a user-visible tracking-state control that changes the selected
  hardware's actual collection/reporting state; the current armed/disarmed
  protection fact is not that control;
- prove iPhone Bluetooth/location/notification denial cannot be bypassed by any
  bridge or lifecycle path;
- prove physical labelling and any audible/visible indications for the intended
  personal-tracking use;
- run the shared workflows, revocation and safety response on the physical Pi and
  signed iPhone installations;
- define and exercise deployment-specific consent, incident response, backup,
  export and remote-destination deletion procedures; and
- review every physical Action independently before exposing it.

Until these gates pass, repository evidence may claim the implemented software
controls and this abuse analysis, but not production anti-stalking protection or
complete personal-tracking safety.
