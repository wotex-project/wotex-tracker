# Tracker ecosystem and hardware research

Reviewed 2026-09-12. This is an adoption assessment for the existing Tracker
scope, not a list of installed dependencies or qualified devices. The
[source cohort](primary-sources.md) identifies the local WoTEx APIs inspected.
The [implementation plan](../plans/software-implementation.md) is normative
about sequencing; research candidates require their own executable acceptance.

## Decision

Start with an inert Elixir library, upstream `wotex` values and a pure Ruuvi
decoder. Add host-owned Runtime/network integration only after the fixture-to-TD
milestone. Keep firmware, UI, persistence, numerical processing and private AI
integration outside that dependency path. Extend existing protocol owners when
generic capability is missing; do not create a second BLE package.

A bootable appliance is compatible with this design. `hosts/nerves` is the
application that starts services; installing `wotex_tracker` does not. The
optional UI is Phoenix LiveView/HEEx, served to an ordinary browser. Lab may
experiment with these public interfaces but is not required to build or run them.

## Elixir and OTP design baseline

Johanna Larsson's library-design article argues for consumer-controlled instances and
explicit configuration instead of library startup callbacks and global settings.
Apply that rule to first-party WoTEx library facades and resources. A library can
still offer child specifications; a host can intentionally manage a whole device.
This is not a requirement to replace OTP applications such as crypto or to
pretend a dependency with global state is inert.
[Let libraries be libraries](https://jola.dev/posts/let-libraries-be-libraries).

Use structs and pure functions for domain calculations; processes represent
concurrency, resource lifetime or isolation. Pass configuration as arguments and
place failure recovery under the resource owner's supervision. These choices
also match the official [Elixir library guidelines](https://hexdocs.pm/elixir/1.18/library-guidelines.html)
and [design anti-patterns](https://elixir.hexdocs.pm/design-anti-patterns.html).

Avoid repeated JSON passes, growing-list append and repeated linear identity
lookups. Measure copying/retention before adding ETS or caches: sending values to
processes and storing them in ETS has allocation costs, and retained binaries
need separate inspection. Local monotonic deadlines are not portable timestamps.
These are implementation constraints, not measured Tracker speedups.
[Erlang process efficiency](https://www.erlang.org/doc/system/eff_guide_processes.html),
[monotonic time](https://www.erlang.org/doc/apps/erts/erlang.html#monotonic_time/0).

## Nerves and hardware libraries

Release numbers below were checked against Hex package/release metadata on the
review date. They are candidate snapshots, not compatible lock sets. A declared
Elixir requirement is not proof of an OTP/native-toolchain combination. HexDocs
landing pages can lag package releases; the release API is the version authority.

| Candidate | Observed release | Fit and adoption condition |
|---|---|---|
| Nerves / Pi 5 system | [1.15.0](https://hex.pm/api/packages/nerves/releases/1.15.0) / [2.1.2](https://hex.pm/api/packages/nerves_system_rpi5/releases/2.1.2) | Separate firmware host; pin actual target runtime/toolchain and pass physical boot/recovery tests |
| VintageNet | [0.13.12](https://hex.pm/api/packages/vintage_net/releases/0.13.12) | Host networking only; review interface ownership, persistence and connectivity probes |
| nerves_time / nerves_runtime | [0.4.12](https://hex.pm/api/packages/nerves_time/releases/0.4.12) / [0.13.13](https://hex.pm/api/packages/nerves_runtime/releases/0.13.13) | Host time/boot services; explicitly handle unsynchronized time and failed data-partition initialization |
| BlueHeron | [0.5.4](https://hex.pm/api/packages/blue_heron/releases/0.5.4) | HCI design reference and possible experimental host backend; not an accepted multi-instance scanner dependency |
| Circuits UART | [1.6.0](https://hex.pm/api/packages/circuits_uart/releases/1.6.0) | Optional serial adapter when a selected device requires it; native port build and target qualification required |
| Circuits I2C / SPI / GPIO | [2.1.0](https://hex.pm/api/packages/circuits_i2c/releases/2.1.0) / [2.1.0](https://hex.pm/api/packages/circuits_spi/releases/2.1.0) / [2.3.0](https://hex.pm/api/packages/circuits_gpio/releases/2.3.0) | Directly attached hardware only; current BLE/cellular profiles establish no need |

BlueHeron is valuable native Elixir HCI work, but its published 0.5.4 source
starts an application, reads `Application.get_all_env(:blue_heron)` and starts
globally named services. Its documented roles and low-level scan commands are
not evidence of a ready, caller-isolated passive observer for Tracker. Inspect
the actual transport/controller ownership before any experiment. Any reusable
WoTEx BLE extension belongs in `wotex_ble`; preserve that repository's accepted
native-backend direction rather than swapping stacks on the strength of a README.
[BlueHeron release application](https://github.com/blue-heron/blue_heron/blob/v0.5.4/lib/blue_heron/application.ex),
[BlueHeron documentation](https://hexdocs.pm/blue_heron/readme.html).

Circuits UART exposes explicit serial operation and active/passive receive modes;
its published application specification has no startup callback. It still needs
a native port build. Prefer this existing boundary to a new Python serial service
if serial ingress is actually selected. Circuits buses are not BLE scanners.
[UART documentation](https://hexdocs.pm/circuits_uart/readme.html),
[published UART source archive](https://repo.hex.pm/tarballs/circuits_uart-1.6.0.tar).

The Pi 5 system documentation marks Bluetooth **untested** and describes board
EEPROM and firmware-validation requirements. Begin with fixture/network ingress
and qualify radio support separately. The Nerves runtime's default data-partition
initialization can reformat an unmountable filesystem; a durable Tracker host
must explicitly preserve or report failure to recover prior state. Neither a
cross-build nor an HTTP response proves safe recovery. WTR.14 contains the
separate headless, UI-enabled and physical acceptance lanes.
[Pi 5 documentation](https://nerves-system-rpi5.hexdocs.pm/readme.html),
[Nerves runtime](https://hexdocs.pm/nerves_runtime/readme.html).

## Network, storage, Nx and UI candidates

| Candidate | Observed release | Recommendation |
|---|---|---|
| Thousand Island | [1.5.0](https://hex.pm/api/packages/thousand_island/releases/1.5.0) | Preferred evaluation for a later Elixir TCP listener when OTP sockets alone are insufficient; host-owned, bounded sessions/frames |
| Ranch | [2.3.0](https://hex.pm/api/packages/ranch/releases/2.3.0) | Established Erlang alternative to evaluate if existing host integration favors it; do not add two acceptor stacks |
| Exqlite | [0.40.0](https://hex.pm/api/packages/exqlite/releases/0.40.0) | Optional SQLite host adapter after an exact transaction/recovery contract; native target builds and data migrations need evidence |
| Tortoise311 | [0.12.3](https://hex.pm/api/packages/tortoise311/releases/0.12.3) | MQTT client candidate only behind the host's binding port; inspect its application startup and protocol requirements |
| emqtt | [1.16.1](https://hex.pm/api/packages/emqtt/releases/1.16.1) | Alternative when MQTT capabilities justify it; inspect native QUIC dependency/build behavior before adoption |
| Nx | [1.0.0](https://hex.pm/api/packages/nx/releases/1.0.0) | Defer; local `wotex_nx` currently requires `~> 0.13.1`, which excludes 1.0.0 |
| Phoenix / LiveView | [1.8.13](https://hex.pm/api/packages/phoenix/releases/1.8.13) / [1.2.11](https://hex.pm/api/packages/phoenix_live_view/releases/1.2.11) | Optional host UI; no Phoenix types or dependencies in core contracts |

Thousand Island offers an explicitly supervised listener rather than requiring
Tracker to invent an acceptor pool. Its inspected 1.5.0 archive declares standard
OTP applications and no application startup callback. This does not supply
protocol framing, admission, authorization or commit semantics: implement and
test those at the appropriate boundaries. Keep arbitrary socket callbacks outside
pure decoding.
[Thousand Island API](https://hexdocs.pm/thousand_island/ThousandIsland.html),
[published source archive](https://repo.hex.pm/tarballs/thousand_island-1.5.0.tar).

The inspected Tortoise311 release has an application callback. emqtt documents
several MQTT versions and a build switch for excluding QUIC, while its Hex
release declares `quicer`. Neither is automatically a pure-core fit. The existing
WoTEx MQTT binding already separates a client port from protocol mapping; test
one selected client's exact QoS, reconnect and timeout behavior in the host.
[Tortoise311 source archive](https://repo.hex.pm/tarballs/tortoise311-0.12.3.tar),
[emqtt documentation](https://github.com/emqx/emqtt/blob/master/README.md),
[emqtt release dependencies](https://hex.pm/api/packages/emqtt/releases/1.16.1).

Nx is useful when a measured numerical workload exists. `Nx.Serving` provides
batching/serving patterns for such a consumer; it is not needed to decode fixed
frames or implement deterministic baseline tracking. `wotex_nx` currently
converts numerical values; it does not perform fusion or run a model. Nx 1.0.0
was released on 2026-09-10, outside that sibling's constraint, and its archive
has an application callback. A future integration must assess the accepted
version and backend rather than forcing an upgrade in this planning change.
[Nx Serving](https://hexdocs.pm/nx/Nx.Serving.html),
[Nx 1.0.0 source archive](https://repo.hex.pm/tarballs/nx-1.0.0.tar).

LiveView keeps projections and interaction close to Elixir. Authenticate both
disconnected and connected mounts, authorize operations at the service, and
handle revoked access on existing sessions. HEEx rendering does not itself
establish authorization. Browser maps may use a small hook; that does not justify
a second canonical state engine or SPA framework.
[LiveView security model](https://hexdocs.pm/phoenix_live_view/security-model.html).

## Patterns from existing tracking systems

These comparisons inform contracts. They do not propose importing another
product or copying its source without reviewing its license and suitability.

| Project | Concrete pattern to borrow | Tracker boundary and caution |
|---|---|---|
| [Traccar architecture](https://www.traccar.org/architecture/) | Separate byte-stream framing from protocol decoding; allow login/ack messages without a position and frames with multiple records; serialize state transitions per device and preserve newer current positions | Pure codecs plus bounded host ingress and WTR.05/06 transactions; no Java/Netty dependency, fleet administration or copied enrichment pipeline |
| [OwnTracks JSON](https://owntracks.org/booklet/tech/json/) | Typed messages, explicit units, and separate fix time from message-construction time | Preserve source semantics and optionality; its platform-specific omissions do not justify replacing missing data with zero or using transport topics as public identity |
| [ChirpStack integration events](https://www.chirpstack.io/docs/chirpstack/integrations/events.html) | Keep network deduplication identity, raw payload and multiple gateway reception records; distinguish downlink acknowledgement from transmission acknowledgement | A future LoRaWAN adapter retains reception provenance; neither acknowledgement alone proves a physical Action or exactly-once state publication |
| [ESPHome Ruuvi support](https://esphome.io/components/sensor/ruuvitag/) | Shared passive BLE reception with a separate device-format decoder and selected sensor projections | Reuse the separation in Elixir; no requirement for ESPHome firmware, global MAC-based identity, or an external decoder runtime |

Ruuvi's official RAWv2 reference remains the wire authority for the first decoder.
Use source-derived vectors and later independent real captures, with per-field
availability and quality preserved. A sequence/movement counter is evidence for
a specified rule, not an automatic alarm. Detailed frame and sentinel acceptance
belongs in WTR.03 rather than a second competing protocol description here.
[Ruuvi RAWv2](https://docs.ruuvi.com/communication/bluetooth-advertisements/data-format-5-rawv2).

## Remaining evidence and limits

This review inspected local source, documentation, release metadata and selected
published source archives. It did not compile candidate dependencies together,
build firmware, test a Pi/radio, run private Refpath, or qualify a commercial
tracker. Package age, download counts and documentation volume were not treated
as reliability measurements. Native libraries still require native platform tests.

The Teltonika Codec wiki was inaccessible during the original review. A later
2026-09-20 review obtained the manufacturer's current Codec 8 Extended layout,
TAT140 codec-selection page and shared AVL ID table. The pure TCP frame decoder,
exact protocol fixture and documentation-derived TAT140 movement/battery mapping
are implemented and separately provenanced in the
[Codec record](teltonika-codec8e-fixtures.md) and
[TAT140 record](teltonika-tat140-fixtures.md). This does not establish IMEI
authentication, selected firmware, direct-endpoint behavior or physical
qualification. Existing hardware names remain research candidates in the
qualification ledger.
[Teltonika Codec reference](https://wiki.teltonika-gps.com/view/Codec).

Refpath is private and under development. Public synthetic connector tests and
a labelled promotional demonstration can be developed under WTR.11; only actual
private execution establishes interoperability. Default installation, compilation,
tests and deterministic operation must all work with Refpath absent and disabled.
