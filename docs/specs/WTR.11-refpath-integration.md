# WTR.11 Optional Refpath AI integration

## Status

Public synthetic boundary implemented. The service provides the
provider-neutral, current-revision tool projection and the explicitly started,
bounded connector described below. No public or private provider exchange,
physical proposal execution or private Refpath interoperability is claimed.

## Boundary

Refpath is an optional AI/agent engine above validated WoT semantics. Tracker MUST compile, run, discover, decode, materialise Things, evaluate deterministic rules, generate alarms and enforce physical-action authorization with Refpath absent.

Refpath is private and under development. It is absent and disabled by default in public packages, hosts and firmware. Private availability is not inferred from a module name, a configured endpoint or a promotional example.

The required prompted-query capability in WTR.16 has a public-provider path
independent of this connector. Refpath can add investigations and governed
proposals, but cannot become the prerequisite for analytics, saved dashboards
or the complete application's deterministic workflows.

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

The first public boundary is `Wotex.Tracker.Service.agent_tools/5`. It admits an
exact `wtr.agent-projection-request.v1` disclosure policy naming one Thing,
expected current generation, read-only Properties and proposal-only Actions.
After ordinary `read` authorization it refetches the current Thing, rejects a
stale generation and emits `wtr.agent-tools.v1`. Tool identities bind the Thing,
generation, affordance kind, name and operation. The response supports only
closed boolean, integer, number and string schemas with bounded compatible
constraints. Forms, URLs, credentials, observations and retained state never
enter the projection. Object, array, composition, writable Property and
undeclared-affordance requests fail closed.

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

`Wotex.Tracker.Service.AgentConnector` is the public synthetic connector. The
exact `wtr.agent-connector.v1` configuration requires explicit enablement,
HTTPS provider endpoint, private authorization and finite deadline, event,
response and concurrency limits. Disabled configuration returns `:ignore` and
starts no process. A missing or callback-incompatible adapter starts in an
`unavailable` state without touching ordinary Tracker work. Each investigation
reauthorizes its exact disclosure through `Service.agent_tools/5` before the
provider worker receives `wtr.agent-provider-request.v1`.

Provider work runs in a linked, monitored process. Explicit cancellation,
caller loss, deadline expiry, malformed or excessive streaming output, crashes,
throws and kills terminate that work without stopping the connector. Only
ordered `wtr.agent-stream-event.v1` text deltas and an exact
`wtr.agent-provider-result.v1` completion are accepted. Action output is checked
against the projected primitive input schema and classified by a closed
`wtr.agent-proposal-policy.v1` allowlist as `denied` or `pending_review`; the
connector has no execution path. Authorization is available only to the
host-supplied adapter configuration and is redacted from inspection and status.

The public suite versions the projection and connector schemas and tests
Thing-plus-affordance identity, explicit unsupported schema constructs, numeric
fidelity, stale TD revisions, cancellation, absence, synthetic streaming,
connector failure and policy-denied proposals. Any later execution boundary
must authenticate and reauthorize again; projection or `pending_review` never
authorizes an Action. Raw tracking history and credential material require
separate explicit disclosure policy. A private integration suite remains
optional and honestly unavailable without its prerequisites.
