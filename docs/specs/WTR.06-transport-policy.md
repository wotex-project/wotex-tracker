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

## Acknowledgements

An RF transmission is not delivery evidence. Policies that escalate after failed delivery MUST define what acknowledgement means at each layer: radio acknowledgement, LoRaWAN confirmed uplink, application acknowledgement, cellular socket/protocol acknowledgement, or durable server admission.

## Sweden baseline

Initial Swedish deployments target current 4G/5G IoT bearers rather than assuming legacy 2G availability. LTE-M/NB-IoT support is preferred for low-power cellular profiles where operator/device support is qualified; Cat-1/Cat-1 bis remains valid where its coverage/energy characteristics fit.

EU868 LoRaWAN MAY be used under applicable European/Swedish short-range-device constraints. Duty-cycle, airtime and payload limits mean LoRaWAN is suitable for sparse telemetry/alarms, not high-rate location streaming.

## Cost and power

`cost_class` and `power_class` SHOULD be explicit policy inputs rather than hard-coded assumptions. Cellular may be more expensive in energy/operations than a local LoRaWAN path, but policy must be able to override that for critical events.

## No false nationwide LoRa assumption

The system MUST NOT treat LoRa/LoRaWAN as guaranteed nationwide coverage. Own gateways, community networks and commercial LoRaWAN operators are separate deployment choices. Cellular fallback exists precisely because LoRa availability is not universal.
