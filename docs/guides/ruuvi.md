# Imported Ruuvi RAWv2 decoding

This path consumes caller-supplied observations and immutable catalogue values.
It performs no scanning, GATT connection, storage, enrollment or publication.

```elixir
alias Wotex.Tracker.{Catalogue, Decoder, Observation, Resolution}
alias Wotex.Tracker.Decoders.RuuviRawV2

{:ok, profile} = RuuviRawV2.profile()
{:ok, catalogue} = Catalogue.new([profile])
{:ok, manufacturer} = RuuviRawV2.manufacturer_data(
  Base.decode16!("99040512FC5394C37C0004FFFC040CAC364200CDCBB8334C884F")
)
{:ok, observation} = Observation.new(Map.merge(manufacturer, %{
  id: "source-example-ordinary", observed_at: 1_700_000_000_000, ingress: "ble",
  source: %{"receiver_id" => "documentation-import"}, addressing: %{}, radio: %{},
  provenance: %{"kind" => "fixture", "source" => "ruuvi-format-5-documentation"}
}))
{:ok, resolution} = Resolution.resolve(observation, catalogue)
{:ok, decoded} = Decoder.run(observation, resolution, catalogue,
  {RuuviRawV2.revision(), &RuuviRawV2.decode/1})
```

The decoder reference and callable are supplied together by trusted caller code.
No callback runs for unresolved/ambiguous inputs or a mismatched revision.
Callbacks return a proper bounded list of `Measurement` values plus native
identity facts, or a validated Tracker error. Bad return shapes become
`invalid_decoder_result`; programming exceptions propagate. This pure seam
is not a sandbox or an asynchronous adapter lifecycle.

Measurements retain kind, native value, unit, availability, quality, raw field
and reason. Source sentinels become unavailable/nil, never zero or NaN. Humidity
above 100% retains its numeric reading with suspect quality. Battery voltage,
TX power and both counters are independent fields. Acceleration unit `g` means
standard gravity in this profile, not mass. The
[fixture provenance](../provenance/ruuvi-raw-v2-fixtures.md) fixes transformations,
source identity and the documented extreme-vector interpretations.

`Decoder.run/5` produces measurement and capability evidence for every declared
field, plus unauthenticated protocol identity facts. Every record names its
observation and exact profile/decoder revisions. Content-derived claim IDs also
bind the immutable catalogue snapshot. The complete raw observation remains in
the returned bundle. Capabilities are readable Properties with evidence links;
missing samples do not remove them. No movement Event, moving/stationary state,
battery percentage, authenticated device identity or physical control is inferred.
The returned protocol MAC remains private evidence, not a public Thing ID.

The profile describes a format family shared by devices, not an exact Ruuvi SKU.
Tests use documentation vectors and synthetic boundaries. Real passive capture,
controller/OS qualification and hardware-to-runtime operation remain unpassed.
