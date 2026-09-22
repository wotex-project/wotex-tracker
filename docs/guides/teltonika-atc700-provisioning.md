# Teltonika ATC700 provisioning and development simulation

WoTEx has a separate, bounded ATC700 provisioning adapter. It prepares a
review-before-use SMS batch and an equivalent Teltonika Configurator (TCT)
manifest for an operator-controlled server. Generating or simulating the plan
does not prove that a physical ATC700, SIM, carrier or firmware accepted it.

## Prepare the service

Select `teltonika.atc700.codec8e` as the host contract. If the cellular listener
is enabled, its device entry must use the matching
`teltonika.atc700.codec8e` profile, a keyed digest of the ATC700 IMEI, and a
service credential with `ingest` authority for the selected scope. The listener
is clear TCP; use appropriate private-network, carrier and firewall controls.
See the standalone host's `Optional cellular listener` instructions for the
complete private configuration document.

The port configured in the tracker must be the cellular listener port, not the
HTTP UI port. The domain must be controlled by the operator and resolve to that
listener.

## Generate and review the device plan

Open the enrolled asset's **Configure tracker hardware** page and choose
**Teltonika ATC700**. Enter:

- the ATC700 SMS password, or leave it empty only when the device has no SMS
  password;
- SIM APN, optional APN username and optional APN password;
- the operator-controlled domain and cellular TCP port.

The adapter emits these exact parameter groups:

| Parameters | Required result |
| --- | --- |
| `2025` | Auto APN disabled (`0`) so the reviewed manual APN is authoritative |
| `2001`, `2002`, `2003` | APN, APN username and APN password |
| `2004`, `2005`, `2006` | Operator domain, port and TCP (`0`) |
| `1004`, `113` | AVL server confirmation (`1`) and Codec 8 Extended (`0`) |

ATC700 SMS authentication is password-only. A configured password is followed
by one space and the command. With no password, the command begins with one
space. Teltonika warns that some iOS messaging paths may remove leading
whitespace, so configuring and using a password is the safer reviewable path.
Do not add the TAT140 login field.

Send the generated SMS commands in order while the modem is reachable. ATC700
does not receive SMS/GPRS commands in Power off sleep. Compare the generated
non-secret `getparam` read-back with every displayed expectation before treating
the plan as applied.

## Apply or verify with TCT

The displayed `wtr.atc700-tct-manifest.v1` plan records the corresponding
selections and makes manual-APN mode explicit:

1. In **SMS / Call settings**, set the reviewed password-only SMS security.
2. In **Mobile network**, disable Auto APN and enter the reviewed APN values.
3. Under the primary server, enter the operator domain and port and select TCP.
4. In **Tracking settings → Records**, select Codec 8 Extended and AVL server
   confirmation.
5. Write the configuration, reconnect or reload it from the device, and compare
   every field with the reviewed plan.

Clear the browser plan after use. It is transient and is not persisted by WoTEx.
Store any sanitized TCT export only as qualification evidence; do not commit
SIM, SMS or service credentials.

## Run the hardware-free ATC700 journey

From `hosts/app`, start the disposable local UI in ATC700 mode:

```sh
WOTEX_PATH_DEPS=1 WOTEX_TRACKER_UI=1 WOTEX_UI_DEVICE=atc700 \
  MIX_ENV=test mise exec -- mix run --no-start scripts/ui_development.exs
```

The script prints the loopback origin, temporary bearer, Thing ID and direct
provisioning URL. It selects the packaged ATC700 service contract and imports
the checksummed `test/fixtures/teltonika/atc700_demo.json` Codec 8 Extended
frame. The fixture includes valid GNSS, movement, battery voltage and battery
percentage so the asset, map, history, statistics and ATC700 setup screens can
be inspected. Stopping the process removes its private temporary store.

The independent wire scenario additionally sends that frame through IMEI login
and the real TCP listener and requires the exact AVL ACK before checking durable
state and statistics. Both paths remain synthetic simulator evidence.

## Physical qualification still required

For a purchased device, record and verify:

- exact regional SKU and firmware;
- SIM/APN and Swedish carrier compatibility;
- SMS and TCT write/read-back behavior;
- real IMEI login and a sanitized Codec 8 Extended packet capture;
- AVL acknowledgement, retransmission and duplicate behavior;
- GNSS, movement, battery voltage and battery percentage mappings;
- sleep/wake, reporting interval, offline buffering and recovery behavior;
- a sanitized hardware fixture and qualification record.

No EYE Sensor or BLE gateway behavior is part of the ATC700 contract.
