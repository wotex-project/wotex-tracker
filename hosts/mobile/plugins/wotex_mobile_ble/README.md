# WoTEx mobile BLE central plugin

This app-owned iOS Mob plugin is a narrow CoreBluetooth central transport seam
for local tracker provisioning. It provides filtered scan, connect, disconnect,
service/characteristic discovery, read and confirmed write primitives. Scans
always require one to eight explicit service UUIDs and stop within 30 seconds.
Connect, disconnect, discovery, read and write operations have a fixed 30-second
native deadline. Writes are confirmed and capped at 512 bytes. Native events return only bounded peripheral
identifiers, display names, RSSI, UUIDs, characteristic properties and values.

The plugin does not implement a tracker protocol, infer identity, accept a BLE
address, select a device, persist values or map GATT into WoT. Reusable BLE/GATT
semantics remain owned by `wotex_ble`; the mobile host must adapt a separately
qualified target profile before claiming provisioning support.

The Mob manifest declares CoreBluetooth and the Bluetooth usage description.
The native NIF is statically linked for an iOS build. On an ordinary host the
Erlang stub reports `nif_not_loaded`, which the Elixir boundary contains as an
explicit unavailable result. Physical permission, radio, lifecycle and target
interoperability require a signed iPhone test.
