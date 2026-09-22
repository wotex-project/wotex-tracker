# TAT140 hardware evidence checklist

## Identity

- [ ] TAT140 exact SKU/order code
- [ ] regional radio variant
- [ ] firmware
- [ ] configuration-tool revision
- [ ] private IMEI/ICCID record
- [ ] public pseudonymous device alias

## Host

- [ ] Pi 3 Model B v1.2 recorded
- [ ] OS image/version
- [ ] kernel
- [ ] architecture
- [ ] Erlang/OTP
- [ ] Elixir
- [ ] WoTEx commit
- [ ] Tracker commit
- [ ] listener configuration digest

## Connectivity

- [ ] operator
- [ ] APN class
- [ ] direct operator-controlled destination
- [ ] TCP connection observed
- [ ] IMEI/login accepted
- [ ] no vendor-cloud dependency

## Protocol

- [ ] real Codec 8 Extended frame
- [ ] CRC/count valid
- [ ] ACK correct
- [ ] sanitized fixture digest
- [ ] duplicate/retransmission case
- [ ] truncated/invalid negative case

## Semantics

- [ ] movement
- [ ] battery
- [ ] GNSS
- [ ] timestamp/freshness
- [ ] profile revision
- [ ] generated or associated Thing Description digest

## Durability

- [ ] service restart
- [ ] store recovery
- [ ] duplicate deduplication
- [ ] upstream outage
- [ ] recovery after outage
- [ ] late historical record does not invent a current alarm

## Privacy and security

- [ ] IMEI/ICCID absent from public fixture
- [ ] SIM/APN secrets absent from repository and logs
- [ ] public Thing ID pseudonymous
- [ ] raw evidence access restricted
- [ ] firewall/listener reviewed
- [ ] vendor cloud not required

## Result

State exactly which evidence class was achieved. Do not call the device
hardware-qualified while any required hardware gate remains unrun.
