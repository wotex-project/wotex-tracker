# WTR.11 Optional RefPath AI integration

## Status

Accepted target contract. No implementation claim.

## Boundary

RefPath is an optional AI/agent engine above validated WoT semantics. Tracker MUST compile, run, discover, decode, materialise Things, evaluate deterministic rules, generate alarms and enforce physical-action authorization with RefPath absent.

## Natural integration

Validated WoT affordances may be projected into RefPath as policy-bound tools/context:

```text
physical device -> Tracker evidence -> validated TD -> Wotex Runtime
                                                |
                                                v
                                      optional RefPath connector
                                                |
                                  agent context / proposed tool call
                                                |
                                      deterministic policy gate
                                                |
                                         WoT interaction
```

Examples include asking which tracked assets are at risk, investigating a cold-chain excursion, correlating a movement alarm with maintenance/history, generating an incident report, or proposing a diagnostic Action.

## Tool projection

A RefPath integration SHOULD derive tool schemas from validated Thing affordances rather than hand-copying device APIs. Tool identity MUST include the Thing and affordance identity. Input/output schemas derive from WoT DataSchemas where compatible.

Read-only Properties may have lower risk than writable Properties or Actions. Event subscriptions are context streams, not model-owned processes.

## Policy

RefPath policy/audit may add an additional governance layer, but it does not replace Tracker/WoT authorization. A model proposal is never evidence that a physical operation succeeded.

High-risk physical Actions SHOULD require deterministic eligibility plus RefPath/human approval policy as configured. Credential substitution occurs at the execution boundary; device credentials are never placed in model prompts.

## No AI identification

An LLM MAY help an operator research an unknown device or suggest a candidate profile for human review. Such output MUST remain `untrusted_suggestion` and cannot create identity/capability evidence, publish a TD, or authorize an Action.

## Packaging

The RefPath adapter SHOULD be optional and isolated so `wotex_tracker` has no hard dependency on private RefPath repositories. A public protocol/connector surface is preferred. If a RefPath-specific package becomes substantial, it belongs in RefPath's plugin/connector ecosystem rather than WoTEx core.
