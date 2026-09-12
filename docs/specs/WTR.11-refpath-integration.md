# WTR.11 Optional Refpath AI integration

## Status

Accepted target contract. No implementation claim.

## Boundary

Refpath is an optional AI/agent engine above validated WoT semantics. Tracker MUST compile, run, discover, decode, materialise Things, evaluate deterministic rules, generate alarms and enforce physical-action authorization with Refpath absent.

Refpath is private and under development. It is absent and disabled by default in public packages, hosts and firmware. Private availability is not inferred from a module name, a configured endpoint or a promotional example.

## Natural integration

Validated WoT affordances may be projected into Refpath as policy-bound tools/context:

```text
physical device -> Tracker evidence -> validated TD -> Wotex Runtime
                                                |
                                                v
                                      optional Refpath connector
                                                |
                                  agent context / proposed tool call
                                                |
                                      deterministic policy gate
                                                |
                                         WoT interaction
```

Examples include asking which tracked assets are at risk, investigating a cold-chain excursion, correlating a movement alarm with maintenance/history, generating an incident report, or proposing a diagnostic Action.

## Tool projection

A Refpath integration SHOULD derive tool schemas from validated Thing affordances rather than hand-copying device APIs. Tool identity MUST include the Thing and affordance identity. Input/output schemas derive from WoT DataSchemas where compatible.

Read-only Properties may have lower risk than writable Properties or Actions. Event subscriptions are context streams, not model-owned processes.

## Policy

Refpath policy/audit may add an additional governance layer, but it does not replace Tracker/WoT authorization. A model proposal is never evidence that a physical operation succeeded.

High-risk physical Actions SHOULD require deterministic eligibility plus Refpath/human approval policy as configured. Credential substitution occurs at the execution boundary; device credentials are never placed in model prompts.

## No AI identification

An LLM MAY help an operator research an unknown device or suggest a candidate profile for human review. Such output MUST remain `untrusted_suggestion` and cannot create identity/capability evidence, publish a TD, or authorize an Action.

## Packaging

The Refpath adapter SHOULD be optional and isolated so `wotex_tracker` has no hard dependency on private Refpath repositories. A public protocol/connector surface is preferred. If a Refpath-specific package becomes substantial, it belongs in Refpath's plugin/connector ecosystem rather than WoTEx core.

## Showcase and acceptance

A promotional integration may demonstrate validated affordances, read-only investigation and governed proposals before Refpath becomes publicly available. Public source can document the intended connector messages and use a synthetic test peer, with no private source or credentials. Label these examples `synthetic showcase`; a private live demonstration records its actual compatible revisions and execution separately. Neither is advertised as generally available public integration.

The connector has explicit enablement, endpoint/provider configuration, authentication, finite deadlines and redacted error/stream limits. Disabled means no connection, background process, model request or compile-time private module dependency. A missing/incompatible provider produces an unavailable result without blocking Tracker boot, discovery, decoding, rules or the ordinary UI.

Before implementation, version the projection/connector schema and test Thing-plus-affordance identity, explicit unsupported schema constructs, numeric fidelity, stale TD revisions, stream cancellation and policy-denied proposals. Authenticate and re-authorize at execution time, not at tool-schema generation. Only validated, authorized projections leave the host; raw tracking history, stable identifiers and credential material require their own explicit disclosure policy. The public suite tests absence, synthetic operation and connector failure; a private integration suite is optional and honestly unavailable without its prerequisites.
