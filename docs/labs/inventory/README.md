# Tracker lab inventory

This ledger records what is physically available, what is verified and what is
still unsafe to wire.

## Current bench

| Item | Electrical / safety domain | Tracker-lab role | Status |
| --- | --- | --- | --- |
| Raspberry Pi 3 Model B v1.2, © Raspberry Pi 2015, fan fitted | 5 V input; 3.3 V GPIO | Development gateway/service host, BlueZ scanner and SQLite/evidence host | Confirmed; fan voltage and pins still need verification |
| 2 × Arduino Nano 33 IoT retail boxes marked WITH HEADERS | 3.3 V GPIO | BLE/Wi-Fi synthetic tracker-adjacent fixtures | Boxes confirmed; inspect actual boards and header state before soldering |
| Arduino Uno R3 | 5 V GPIO | Serial/fault fixture | Confirmed |
| Adafruit PIR Motion Sensor ADA189 | Verify authoritative supply/output before Nano connection | Physical motion source for Nano fixture | Confirmed model; electrical check pending |
| Shelly Motion 2 | Finished Wi-Fi device | Cross-transport motion source | Confirmed; local API/firmware qualification pending |
| AZ-Delivery ESP8266 ESP-01S kit | 3.3 V | Optional independent Wi-Fi peer | Package confirmed; verify programmer voltage |
| Delock smart plug | Mains | Generic interoperability only | Exact model/local protocol unknown; do not open |
| Blue USB adapter | Unknown | Possible UART/programmer | Identify chipset and logic voltage before use |
| Green USB/ESP-style adapter | Unknown | Possible ESP programmer | Identify exact model and voltage before use |
| Plexgear USB dongle | USB | Possible secondary radio | Exact model/function unknown |
| Small round USB dongle | USB | Unknown | Identify from label and `lsusb` |
| Additional bagged green boards/modules | Unknown | Future sensor fixtures | Do not wire until identified |
| Breadboard/electronics kit | Passive/mixed | Low-voltage fixture construction | Available |
| Teltonika TAT140 EU | Finished rugged LTE/GNSS/BLE tracker | Primary real tracker | **Missing / procure** |

## Required next purchase

The **TAT140 EU** plus a Swedish data SIM is the purchase that changes the
Tracker hardware-evidence class. Pi 5 and LoRaWAN hardware are not required for
the first TAT140 qualification lane.

## Admission rule

An unidentified module cannot appear in a wiring diagram. Admit it only after
its model/revision, supply voltage, logic voltage, pinout and authoritative
documentation are known.
