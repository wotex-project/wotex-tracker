# ADR 0002: Evidence before inference

Status: Accepted

## Decision

Physical device identity, capabilities, decoded measurements, position truth, alarms and Thing materialisation are deterministic products of bounded protocol evidence and versioned profiles.

AI output is never accepted as evidence.

## Consequences

- unknown devices remain unknown;
- ambiguous profile matches require more evidence or explicit enrollment;
- every decoded claim retains observation/profile/decoder provenance;
- historical observations are not silently reinterpreted after profile changes; and
- Refpath or another AI may assist an operator only outside the acceptance path.
