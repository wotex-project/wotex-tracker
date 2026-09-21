# WoTEx Tracker physical lab catalogue

Tracker labs are requirement-driven hardware qualification scenarios. Each lab starts from a real tracker class and proves the path from physical evidence to an evidence-backed WoT Thing.

Unlike the generic WoTEx Lab, this catalogue is narrower:
- real tracker hardware;
- real transport/position/motion/battery evidence;
- deterministic profile/capability mapping;
- restart/offline/replay behaviour;
- privacy and identity custody;
- no mandatory vendor cloud.

## Lab sequence

The first admitted tracker lab is `tat140/`.

Future labs may add other finished trackers or transport combinations only when they satisfy the repository's hardware qualification and no-vendor-lock requirements.

## Rules

- One directory per tracker family or qualification scenario.
- Hardware model, regional SKU, firmware and protocol revision are explicit.
- A software fixture is not hardware qualification.
- Unknown radio features remain unqualified until physically observed.
- Generic BLE/HTTP/MQTT semantics remain owned by WoTEx packages; Tracker owns tracker-specific fingerprints, evidence and Things.
- LoRaWAN is optional and belongs in a later tracker lab only if a suitable open device/network path is selected.
- Refpath is optional and never required for hardware qualification.
