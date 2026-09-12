# ADR 0003: Vendor-independent hardware qualification

Status: Accepted

## Decision

No hardware profile is considered supported if normal telemetry requires a mandatory vendor cloud or vendor-controlled API tenancy.

A qualified profile must prove an operator-controlled physical-device-to-ingress path and operator control of required network credentials.

## Consequences

- commercial finished hardware is welcome when its direct protocol is usable;
- optional vendor fleet-management tooling does not disqualify hardware;
- cloud-only integrations remain research examples, not reference profiles;
- LoRaWAN hardware is not selected merely because it has the right radios; and
- uncertainty about openness is treated as failure to qualify, not assumed compatibility.