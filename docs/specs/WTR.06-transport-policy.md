# WTR.06 Transport selection, store-and-forward and fallback

## Status

Accepted target contract. No implementation claim.

## Principle

Transport priority is deployment/device policy, not architecture. LoRaWAN is optional. Cellular may be primary for one profile and last-resort fallback for another.

## Transport facts

A profile may declare transport capabilities such as BLE, LoRaWAN EU868, Wi-Fi/IP, LTE-M, NB-IoT, LTE Cat-1/Cat-1 bis, or another qualified bearer. Tracker MUST distinguish radio/bearer capability from the application protocol used over it.

## Policy

A transport policy consumes explicit state such as device capabilities, connectivity evidence, event severity, power budget, acknowledgement state, roaming/cost class and deployment preference.

Example bike policy:

```text
stationary -> store / sparse local heartbeat
owner nearby -> BLE/local path
normal remote event -> LoRaWAN when qualified and available
LoRa unavailable + ordinary telemetry -> store and retry
LoRa unavailable + theft/tamper/critical alarm -> cellular
active theft mode -> cellular/GNSS cadence permitted by recovery policy
```

This is an example profile, not a mandatory global ordering.

## Store-and-forward

Observations MUST support bounded local or ingress-side store-and-forward where the physical protocol provides it. Deduplication/replay handling MUST use protocol sequence/identity evidence where available rather than timestamp alone.

This is a later host capability, not a persistence requirement for the pure core. Before enabling it, the adapter contract must fix queue count/byte/age limits, admission ordering, overflow outcome, retry budget and restart behavior. An in-memory acknowledgement cannot be described as durable. Lossy radio input exposes drop/overflow evidence; reliable ingresses backpressure or reject admission without acknowledging a commit that did not happen.

## Commit, publication and recovery

A host admission unit atomically checks scoped observation/measurement identity, stores the new evidence and canonical state, applies stale deletion belonging to that update, and records any publication/event intent. Concurrent writers use a conditional version/generation check; a losing writer receives `:conflict` without partially changing state. Reads observe a single committed generation. Independent retention jobs must not invalidate evidence still referenced by that generation without an explicit tombstone policy.

An early development host may start with explicitly volatile per-instance state.
The shipped service and Pi product profiles MUST provide durable observations,
enrollment, policy state, event intents and saved application data. SQLite is the
initial local-store implementation target in the service host; it is not a core
dependency. Pin the actual driver/schema and qualify its native builds, writer
ownership, transaction mode, checkpoint/backup and full-disk behavior. A remote
database remains a deployment choice. Do not implement separate uncoordinated
writes to observation, deduplication and event stores or claim ETS multi-operation
atomicity. Use the store's real transaction boundary, not a generic database framework.

TD publication to Directory or an external endpoint is a separate host effect and cannot be made atomic with local storage by calling two library APIs. Use a persisted publication intent when durable retry is required, bind it to the exact TD/deployment generation, and reconcile the same operation identity. A later generation cannot be overwritten by a stale retry. Retain the last valid published state if preparation/validation fails.

Public host results must distinguish `not_committed`, `committed` (with generation and publication status), and `unknown` when a crash/timeout prevents determining the commit outcome. A committed mutation followed by failed publication/cleanup must not be reported as an ordinary pre-commit failure inviting duplicate admission. Cleanup failure after successful publication reports publication success plus a separate cleanup failure. Retrying an unknown physical Action is never automatic.

Before the durable lane is accepted, inject failure before commit, after commit before acknowledgement, during publication, after publication before local confirmation, and during stale deletion/cleanup. Race duplicate submissions and concurrent updates; restart the host; prove no mixed snapshot, lost deduplication record or spurious repeated live alarm. Ordinary filesystem staging checks do not provide containment against a hostile concurrent writer; any file-backed adapter must state its actual filesystem/crash assumptions and reject unsafe paths without claiming portable race-proof security.

## Acknowledgements

An RF transmission is not delivery evidence. Policies that escalate after failed delivery MUST define what acknowledgement means at each layer: radio acknowledgement, LoRaWAN confirmed uplink, application acknowledgement, cellular socket/protocol acknowledgement, or durable server admission.

The cellular listener specification must define exactly which accepted records an acknowledgement covers and whether acceptance is volatile or durable. A checksum and a socket acknowledgement establish neither authenticated identity nor a physical Action effect. A timeout means the outcome may be unknown; it does not imply remote rollback. Protocol-required retransmission and deduplication are qualified together.

The production admission contract records per-record disposition and its stable
measurement/operation identity. Atomic versus partial batch admission is explicit
for each protocol; one accepted count cannot conceal rejected records. A repeated
frame after a lost ACK must neither duplicate history nor retrigger an alarm.
Protocol ACK timing that precedes durable commit must be identified as transport
acceptance and cannot be sold as lossless admission. Device-effect evidence stays
separate from command acceptance, send success and acknowledgement.

## Sweden baseline

Initial Swedish deployments target current 4G/5G IoT bearers rather than assuming legacy 2G availability. LTE-M/NB-IoT support is preferred for low-power cellular profiles where operator/device support is qualified; Cat-1/Cat-1 bis remains valid where its coverage/energy characteristics fit.

EU868 LoRaWAN MAY be used under applicable European/Swedish short-range-device constraints. Duty-cycle, airtime and payload limits mean LoRaWAN is suitable for sparse telemetry/alarms, not high-rate location streaming.

## Cost and power

`cost_class` and `power_class` SHOULD be explicit policy inputs rather than hard-coded assumptions. Cellular may be more expensive in energy/operations than a local LoRaWAN path, but policy must be able to override that for critical events.

## No false nationwide LoRa assumption

The system MUST NOT treat LoRa/LoRaWAN as guaranteed nationwide coverage. Own gateways, community networks and commercial LoRaWAN operators are separate deployment choices. Cellular fallback exists precisely because LoRa availability is not universal.
