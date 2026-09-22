# Tracker lab network and credential security

## Principles

- Tracker telemetry terminates on operator-controlled infrastructure.
- Management access and tracker ingress are separate.
- Raw device identifiers are private.
- Public Thing identity is pseudonymous.
- No vendor cloud is mandatory.
- Every listener is bounded.

## Development network

Recommended:

- wired Pi management;
- isolated test Wi-Fi/VLAN for Nano and Shelly devices;
- firewall default deny inbound;
- one explicit tracker-ingress port;
- SSH key authentication from the trusted management network only.

## Mobile ingress

If a home ISP uses CGNAT, do not work around it by opening random ports or
adding a vendor cloud. Use an operator-controlled public host, VPN or tunnel
that terminates or routes the bounded protocol to the lab.

## Secrets

Never commit:

- IMEI/ICCID lists;
- SIM PIN/APN passwords;
- BLE bonding keys;
- private VPN keys;
- LoRaWAN keys;
- vendor account tokens.

Evidence manifests reference secret slots or pseudonymous aliases, never raw
secrets.
