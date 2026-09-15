# Observations, evidence and identity

The WTR.01 constructors execute in the caller with no clock reads, processes,
network access, persistence, authorization or device inference.

```elixir
alias Wotex.Tracker.Observation

{:ok, observation} = Observation.new(%{
  id: "capture-1",
  observed_at: 1_700_000_000_000,
  ingress: "ble",
  source: %{"receiver_id" => "import-1"},
  addressing: %{"address_type" => "random"},
  payload: {:bytes, <<5, 0>>},
  radio: %{"rssi" => -70},
  transport: %{},
  provenance: %{"kind" => "fixture", "source" => "synthetic-example-v1"}
})
{:ok, map} = Observation.to_map(observation)
{:ok, identical} = Observation.from_map(map)
true = Observation.same?(observation, identical)
{:ok, content_id} = Observation.identity(observation)
```

The two-byte example is only a capture envelope; it is not a valid device frame.
Physical ingress is one of `ble`, `cellular`, `lorawan`, `mqtt`, `http`, `serial`,
`imported`. Imported BLE remains `ble` with explicit fixture/replay provenance.
Receiver Unix milliseconds are integers; device/fix clocks remain separately
named source metadata. Monotonic deadlines never enter this envelope.

All constructor fields are explicit atom keys. Wire maps use string keys and
`schema: "wtr.observation.v1"`; bytes use a tagged canonical Base64 envelope.
`from_json/2` uses upstream bounded parsing and rejects duplicate members before
map conversion. A caller supplying an already converted native map cannot claim
that the original source was duplicate-free. Wide integers and native float/int
distinctions survive the Elixir wire parser. Browser-safe projection is later
host work; raw evidence must not travel through a lossy JavaScript re-encoder.

Limits are explicit positive keyword options; unknown/repeated/invalid options
fail. Each metadata object and JSON payload obeys WTR.13's default JSON limits;
raw bytes have their own 65,536-byte limit. JSON export/digest budgets separately
account for the envelope, admitted metadata and Base64 expansion. Limits bound
subsequent traversal, not memory a caller allocated beforehand.

`Evidence.new/2` requires an ID, fixed kind/confidence, native claim object,
nonempty source observation IDs, parent evidence IDs, profile/decoder revision
pairs, reasons and an explicit association ID or `nil`. Units, availability,
quality and native measurements belong in the claim; no missing sample becomes
an invented zero. Claims are untrusted interpretations until their owning
profile/decoder has been qualified.

`EvidenceBundle.new/3` admits bounded lists, indexes them and validates a closed
lineage graph. Equal repeated IDs are idempotent only under type-strict equality.
Unequal duplicates, missing references, cycles, excess depth, conflicting
profile/decoder revisions and multiple association IDs fail explicitly. The
first slice represents one profile/decoder revision pair in each bundle. Shared
parents are memoized so traversal remains bounded by admitted nodes and edges.
The aggregate exported claim JSON also has a separate 65,536-byte budget.

Bundle identity uses upstream canonical JSON with a versioned Tracker domain
marker and SHA-256. It includes every evidence field and full observation content
identities. This is a consistency check, not authentication or RFC 8785 conformance.
Bundle validation recalculates the digest and checks index keys. Public domain
boundaries revalidate structs; a struct tag alone proves nothing.

`Identity.new/3` accepts explicit `thing_id`, `association_id`, `revision` and
`evidence_id` plus the immutable bundle. The first strategy requires a lowercase
UUIDv4 URN. Its identity evidence must carry the same association, all source
observation IDs, and a claim with `thing_id`, `revision` and
`strategy: "operator-pseudonym-v1"`. It binds the resulting value to the complete
bundle. The caller issues the random pseudonym and supplies enrollment evidence;
Tracker neither hashes a MAC/IMEI nor stores an association. Format confidence
never grants enrollment, authentication, publication or physical-operation rights.

Profiles, decoding and materialisation extend this boundary in subsequent
milestones. Existing observations remain representable before any profile exists.
