# Specification readiness review — 2026-09-12

## Outcome and scope

The confirmed specification gaps below are addressed in the revised contracts and
implementation plan. This is **specification hardening**, not a completed Tracker
library, performance optimization, firmware image or hardware qualification.
All implementation milestones and catalogue evidence promotions remain not started.

The read-only audit preceded edits and its full findings were presented to the
user. Baseline: `d1a54ec5eb9c30f068c9eb37f135f8655e379829`, a clean Tracker
checkout containing 22 tracked documentation/catalogue files. No Mix project,
Tracker implementation, tests, CI configuration or LICENSE file existed.
README's Apache-2.0 intent is recorded; package foundation still must supply the
license and required notices.

The review covered Tracker instructions, README, decisions, specifications,
catalogue, plan and provenance, plus sibling instructions, declared dependencies,
tests/CI and source at the seams recorded in [source provenance](primary-sources.md).
The 15 sibling libraries and optional Lab were inspected for ownership and
integration fit. This was not a full correctness/security audit of every sibling.
No article-related first-party ownership violation was confirmed that warranted a
cross-repository edit. All 16 sibling checkouts remained clean at their original
revisions.

## Confirmed findings and resolutions

Locations in this section refer to the **baseline revision**, so line numbers
remain reproducible with `git show d1a54ec:<path>`. Severity describes the
implementation risk of an unresolved contract, not an observed production exploit.
Failure scenarios are contract counterexamples unless explicitly identified as
executed probes.

### 1. High — duplicate BLE ownership and unsupported scanning assumption

**Location:** `docs/specs/WTR.10-wotex-integration.md:47`,
`docs/specs/WTR.03-device-profiles-and-adapters.md:48`,
`docs/plans/software-implementation.md:78`.

**Evidence/impact:** the plan proposed creating `wotex-binding-ble`, although
`wotex_ble` already owns BLE/GATT values and WoT mapping. Its `discover/2`
discovers GATT characteristics on a selected session; it does not prove a
passive advertisement scanner. Its accepted native backend target and current
backend must also be distinguished. Following the original plan could duplicate
protocol ownership and claim an unavailable acquisition capability.

**Smallest fix/resolution:** use the existing owner, qualify missing passive
scanning separately, and record the actual source/native status.
[WTR.10 ownership and integration](../specs/WTR.10-wotex-integration.md) and
plan Phase 4 now do so; no upstream backend was replaced.

### 2. High — materialisation lacked an implementable contract

**Location:** `docs/specs/WTR.04-thing-materialisation.md:25`.

**Evidence/impact:** the input equation ended in a validated TD but specified no
supported TM subset, affordance omission, identity replacement, security or Form
rules. Upstream `ThingModel.from_map/2` validates models and exports no
materialise/instantiate operation. A valid TM is not automatically a usable TD,
and a structurally valid TD does not prove an installed/reachable endpoint.

**Smallest fix/resolution:** one self-contained environmental model, explicit
capability mapping, typed unsupported-feature/missing-capability errors,
explicit deployment/security, retained provenance and upstream native-map
validation. [WTR.04](../specs/WTR.04-thing-materialisation.md) separates the pure
TD milestone from a real Runtime/host interaction. Constructor/export/pointer
assumptions passed the isolated source probes; Tracker materialisation is unbuilt.

### 3. High — identity and snapshot coverage were incomplete

**Location:** `docs/specs/WTR.01-observation-identity-evidence.md:46` and
`:64`; its unresolved-match rule at `:79`.

**Evidence/impact:** profile/decoder labels and observation references were listed
without collision, dangling/cyclic reference, immutable-content, model/mapping or
deployment coverage rules. Changing a profile between resolution and decoding,
or reusing an observation ID for unequal content, had no specified rejection.
Candidate eligibility and tie behavior could also depend on an implementation's
iteration order.

**Smallest fix/resolution:** one immutable pipeline snapshot, complete revision/
association coverage, type-strict idempotence, separate reception identity, and
explicit conflict/replay semantics in [WTR.01](../specs/WTR.01-observation-identity-evidence.md).
[WTR.02](../specs/WTR.02-discovery-and-capabilities.md) now resolves only a unique
highest eligible exact/strong match; candidate-only input is unknown with
insufficient evidence, and equal highest eligible matches are ambiguous.
The follow-up review aligned that rule across WTR.01/02/07.

### 4. High — blanket range rejection could discard valid unavailable samples

**Location:** `docs/specs/WTR.03-device-profiles-and-adapters.md:64`.

**Evidence/impact:** the decoder rule rejected impossible ranges without defining
protocol sentinels, partial availability or quality. The authoritative RAWv2
unavailable vector is a correctly framed 24-byte record; its sentinel fields are
not ordinary measurements. The standalone bit-layout probe passed on both lanes.
No Tracker decoder currently exists to exhibit data loss.

**Smallest fix/resolution:** distinguish framing/version failures from admitted
per-field unavailable/suspect values; preserve valid mixed measurements, units and
raw evidence. [WTR.03](../specs/WTR.03-device-profiles-and-adapters.md) adds
independent ordinary/extreme/unavailable/mixed fixture acceptance without
inventing battery percentage, movement Events or authenticated identity.

### 5. High — JSON and binary serialization were ambiguous

**Location:** `docs/specs/WTR.01-observation-identity-evidence.md:11`.

**Evidence/impact:** `bounded_bytes_or_value` and an open atom vocabulary did not
fix JSON types, byte export or duplicate-key handling. A lossy decode can erase
duplicate members; `%{:id => 1, "id" => 2}` is not an unambiguous JSON object.
Core rejects both cases. Its canonical bytes distinguish integer 1 from float
1.0 even though ordinary Elixir equality equates them; these probes passed.

**Smallest fix/resolution:** explicit bytes/native-JSON alternatives, fixed
admitted ingress names, upstream bounded JSON admission, strict equality and a
versioned Base64 wire envelope. [WTR.01](../specs/WTR.01-observation-identity-evidence.md)
and [WTR.07](../specs/WTR.07-headless-interfaces.md) require exact machine schemas
before endpoints ship. No second serializer or atom-generating decoder was added.

### 6. High — resource bounds and live ownership were not actionable

**Location:** `docs/specs/WTR.01-observation-identity-evidence.md:83`;
`docs/plans/software-implementation.md:10`.

**Evidence/impact:** finite limits were required without initial values or the
lifecycle acceptance needed for queues, owners, deadlines and stale replies.
A length check after fully enumerating input cannot bound that work, and mailbox
sampling cannot establish a hard allocation limit.

**Smallest fix/resolution:** [WTR.13](../specs/WTR.13-elixir-otp-and-verification.md)
sets conservative first-slice budgets, explicit errors and traversal rules.
It makes exact per-adapter budgets and two-instance/owner-loss/backpressure/
stale-generation tests prerequisites to live implementation. Budgets are design
choices pending measurement; they are not performance guarantees.

### 7. High — persistence, publication and acknowledgement outcomes were undefined

**Location:** `docs/specs/WTR.06-transport-policy.md:32` and `:36`.

**Evidence/impact:** store-and-forward and layered acknowledgement were required
without a transaction/generation/commit contract. A crash after commit but before
acknowledgement, or publication followed by cleanup failure, could be interpreted
as an ordinary failed write and retried incorrectly. Separate stale deletion
could invalidate the last valid state.

**Smallest fix/resolution:** [WTR.06](../specs/WTR.06-transport-policy.md) makes
deduplication/evidence/state/deletion/event intent one host admission unit,
distinguishes committed/not-committed/unknown outcomes, and separates Directory
publication with generation-bound retry. Start volatile; accept durable storage
only after failure injection. It explicitly avoids portable hostile-writer
containment claims. Exact device acknowledgement schemas still require the
selected protocol reference before Phase 5.

### 8. Medium — the pure milestone acquired unnecessary integration commitments

**Location:** `docs/plans/software-implementation.md:8` and `:23`.

**Evidence/impact:** Runtime was included in foundation dependencies and discovery/
registry/clock ports in a zero-process imported-fixture milestone. Those interfaces
are unnecessary for the first calculation and could couple consumers to
unreleased packages or host policy.

**Smallest fix/resolution:** core-only `wotex` first; immutable catalogue, explicit
identity/time inputs, and behaviours only at actual substitution seams.
[WTR.00](../specs/WTR.00-library-contract.md) and
[WTR.10](../specs/WTR.10-wotex-integration.md) also make Lab optional and accurately
limit Nx to numerical conversion, Continuum to inert exchange, and conformance
to an external artifact/evidence boundary. No optional dependency was installed.

### 9. Medium — phase ordering contradicted acceptance dependencies

**Location:** `docs/plans/software-implementation.md:42`, `:52`, `:54`, `:56`.

**Evidence/impact:** materialisation preceded the concrete Ruuvi decoder, while
the BLE phase required a Runtime observation before the host phase. The stated
fixture milestone and the numbered phases did not identify the same executable
path.

**Smallest fix/resolution:** [the plan](../plans/software-implementation.md) now
orders foundation -> observation/resolution/decoder -> narrow materialisation ->
explicit host/Runtime -> separately qualified live ingress. Optional LiveView
can follow the host without waiting for cellular, LoRaWAN, Pi or Refpath.
One `Resolution` value is used consistently.

### 10. Medium — runtime, artifact and evidence gates were underspecified

**Location:** `docs/plans/software-implementation.md:88`,
`docs/specs/catalogue.yaml:1`, `docs/provenance/primary-sources.md:13`.

**Evidence/impact:** general hygiene and target-evidence labels did not provide a
runtime matrix, exact inspected cohort, optional-absent archive consumers or a
complete configured gate. Several sibling check configurations disable tools;
copying them would not execute every check named in a completion contract.

**Smallest fix/resolution:** pinned [source cohort](primary-sources.md),
[WTR.12 evidence classes](../specs/WTR.12-evidence-and-graduation.md),
[WTR.13 runtime/package gates](../specs/WTR.13-elixir-otp-and-verification.md),
and distinct not-started/current/target/evidence-reference catalogue fields.
The complete gate must not silently rerun only failed checks. CI, action pins,
release automation and dependency constraints were not changed.

## User-directed host and research decisions

[WTR.14](../specs/WTR.14-nerves-and-liveview-hosts.md) adds an optional separate
Pi 5 Nerves application, a headless build without Phoenix, and an explicitly
enabled LiveView/HEEx host. Startup belongs to that application's callback.
A bootable host therefore does not alter the root library contract.

[The research assessment](ecosystem-research.md) covers 18 exact public release
references and patterns from Traccar, OwnTracks, ChirpStack and ESPHome, starting
with Nerves/Circuits/BlueHeron/Nx. BlueHeron's current global startup design, the
Nx 1.0 versus local ~> 0.13.1 mismatch, Pi 5 Bluetooth's untested status and Nerves
data-partition recovery behavior are adoption constraints, not patched upstream
defects. No candidate was accepted solely because it is written in Elixir.

[WTR.11](../specs/WTR.11-refpath-integration.md) permits a labelled synthetic
promotional showcase and separate private interoperability evidence. Refpath
remains private, under development, absent and disabled by default. Private
source was not inspected or required.

## Executed verification

Host: macOS 26.6.2, Darwin arm64. Runtime selections were explicit through mise;
the installed OTP_VERSION files confirmed the exact OTP patch releases below.

| Check | Actual result | Scope/limit |
|---|---|---|
| Initial read-only source/contract probes using existing core build artifacts | 6 passed | Preliminary evidence only; not a clean build |
| Isolated core source compile, Elixir 1.18.4 / OTP 27.3.4.15 | Exit 0, warnings as errors | Fresh build from the pinned core source and cached locked production dependency sources |
| Same source, Elixir 1.20.4 / OTP 29.0.4 | Exit 0, warnings as errors | Separate fresh build directory; same dependency sources |
| Final standalone API/JSON/Ruuvi-layout/Nx-constraint probes | 10 passed, 0 failures on each lane | Upstream assumptions only; no Tracker behavior or real endpoint exercised |
| Catalogue and local-document checks before contract commit | 15 contracts; 24 Markdown files; 39 local file links; complete index; exit 0 | File targets, YAML structure/duplicate keys, references and current evidence state; not remote anchors or full Markdown rendering |
| Post-report document and appendix checks | 25 Markdown files, 60 local file links; both documented scripts match the executed probes | Exit 0; isolated and sibling lockfiles byte-identical |
| Adverse catalogue checks | All 5 rejected with the expected reason | Duplicate YAML key, duplicate contract ID, missing file, unknown dependency reference and unsupported evidence promotion |
| Public release references in research report | 18 HTTP/API successes with matching version fields | Metadata verification, not dependency resolution/build compatibility |
| Sibling preservation | 16 clean checkouts at original revisions | No cross-repository edits |
| Git whitespace validation | `git diff --check` and staged equivalent passed | Documentation changes only |

The isolated core came from `git archive` of the provenance revision. Only
`decimal` 3.1.1, `ex_json_schema` 0.11.5 and `jason` 1.4.5 production dependency
sources were copied from the existing cache; no dependency resolver ran and no
repository lock was changed. This is not a freshly downloaded Hex consumer.

The first current-runtime probe run passed but warned about a literal comparison
of statically disjoint numeric types. The probe was changed to compare values
admitted through JSON, which exercises the intended boundary. Both final probe
runs passed without that warning; no suppression or repository change was used.

Commands below were run from the isolated core with a temporary review directory
substituted for `$tracker_review_dir`. The two probe scripts are retained in the
appendix so this evidence is reviewable without relying on local temporary files.

```sh
MIX_ENV=prod MIX_BUILD_PATH="$tracker_review_dir/build-floor" mise x elixir@1.18.4-otp-27 erlang@27.3.4.15 -- mix compile --warnings-as-errors
MIX_ENV=prod MIX_BUILD_PATH="$tracker_review_dir/build-floor" mise x elixir@1.18.4-otp-27 erlang@27.3.4.15 -- mix run --no-start --no-compile "$tracker_review_dir/upstream_probe.exs"
MIX_ENV=prod MIX_BUILD_PATH="$tracker_review_dir/build-current" mise x elixir@1.20.4-otp-29 erlang@29.0.4 -- mix compile --warnings-as-errors
MIX_ENV=prod MIX_BUILD_PATH="$tracker_review_dir/build-current" mise x elixir@1.20.4-otp-29 erlang@29.0.4 -- mix run --no-start --no-compile "$tracker_review_dir/upstream_probe.exs"
ruby "$tracker_review_dir/check_specs.rb" /path/to/wotex-tracker
git diff --check
```

## Limits, deferred decisions and repository state

No Tracker test/gate, doctest, coverage, Credo, Dialyzer, documentation build,
Hex archive or locked/fresh/minimum consumer matrix could run: Tracker has no
Mix project. Those remain Phase 0 and subsequent implementation gates, not
waived checks. Optional integrations present/absent, runtime lifecycle,
transaction fault injection and hardware acceptance remain unexecuted.

No hot path changed, so no benchmark or allocation/RSS comparison was performed.
Before/after performance claims would be unsupported. No firmware was built,
flashed or booted; no BLE/cellular/LoRaWAN hardware or Swedish operator was tested.
The Teltonika Codec wiki returned HTTP 403; exact protocol acceptance remains
blocked on an authoritative accessible reference and selected-device evidence.

Remaining design choices include the actual scanner/backend, cellular firmware/
codec, concrete listener/client/store, durable schema, UI packaging and private
connector protocol. Each is a prerequisite for its own later phase. Full TM
composition, new generic protocol repositories, automatic fleet policy, numerical
fusion/ML backends and a local HDMI kiosk are outside the first milestone.

Local contract fixes are in `f2d961f` (`docs: align tracker with existing WoTEx
library boundaries`) and `c862dfe` (`docs: harden tracker contracts and optional
host acceptance`). This report is recorded in a separate documentation commit.
All changes are within Tracker documentation/catalogue scope. No remote mutation,
push, tag, workflow trigger, publication, release, visibility change or device
operation occurred. Online work was read-only research. Final working-tree and
post-report integrity checks are reported at handoff.

## Reproduction appendix

These are dated audit probes, not Tracker's future test suite or a claim that
Phase 0 tooling exists. Ruby/Psych was an available local document-audit tool;
it is not a Tracker dependency or proposed runtime requirement.

<details>
<summary>Isolated upstream contract probes: upstream_probe.exs</summary>

<!-- probe: upstream -->
```elixir
ExUnit.start()
IO.puts("Runtime: Elixir #{System.version()} OTP #{System.otp_release()}")
defmodule TrackerSpecSourceProbes do
  use ExUnit.Case, async: false
  alias Wotex.{JSON, ThingDescription, ThingModel}

  test "duplicate JSON members are rejected at the core boundary" do
    assert {:error, %Wotex.Error{code: :duplicate_member}} = JSON.decode(~s({"id":1,"id":2}))
  end

  test "atom and string key aliases cannot enter native JSON" do
    assert {:error, %Wotex.Error{code: :non_string_key}} = JSON.validate(%{:id => 1, "id" => 2})
  end

  test "native JSON values retain false, zero, null and numeric types" do
    value = %{"values" => [false, 0, nil, 1, 1.0, "å"]}
    assert :ok = JSON.validate(value)
    assert {:ok, bytes} = JSON.encode(value)
    assert {:ok, decoded} = JSON.decode(bytes)
    assert decoded === value
  end

  test "canonical bytes require type-strict identity equality" do
    assert {:ok, integer_value} = JSON.decode("1")
    assert {:ok, float_value} = JSON.decode("1.0")
    assert integer_value == float_value
    refute integer_value === float_value
    assert {:ok, int} = JSON.encode(integer_value)
    assert {:ok, float} = JSON.encode(float_value)
    refute int == float
  end

  test "native self-contained model constructor preserves extensions" do
    map = %{"@context" => Wotex.td_context_1_1(), "@type" => "tm:ThingModel",
      "id" => "urn:example:model:review", "title" => "Review model",
      "properties" => %{"temperature" => %{"type" => "number", "unit" => "Cel", "readOnly" => true}},
      "tm:optional" => ["/properties/temperature"], "x-review" => [false, 1, 1.0]}
    assert {:ok, model} = ThingModel.from_map(map)
    assert ThingModel.to_map(model) === map
  end

  test "native TD constructor accepts explicit synthetic deployment" do
    map = %{"@context" => Wotex.td_context_1_1(), "id" => "urn:example:review:1",
      "title" => "Review sensor", "securityDefinitions" => %{"basic_sc" => %{"scheme" => "basic"}},
      "security" => ["basic_sc"], "properties" => %{"temperature" => %{"type" => "number",
      "readOnly" => true, "forms" => [%{"href" => "https://example.test/temperature", "op" => "readproperty"}]}}}
    assert {:ok, td} = ThingDescription.from_map(map)
    assert ThingDescription.to_map(td) === map
    assert {:ok, _} = ThingDescription.encode(td, :canonical)
  end

  test "model validation does not provide a materializer" do
    assert {:module, ThingModel} = Code.ensure_loaded(ThingModel)
    assert function_exported?(ThingModel, :from_map, 2)
    refute Enum.any?(ThingModel.__info__(:functions), fn {name, _} -> name in [:materialize, :instantiate] end)
  end

  test "escaped JSON pointer names are supported upstream" do
    name = "a/b~c"
    pointer = JSON.join_pointer("/properties", name)
    assert pointer == "/properties/a~1b~0c"
    assert {:ok, 0} = JSON.resolve_pointer(%{"properties" => %{name => 0}}, pointer)
  end

  test "RAWv2 unavailable vector fits exact field widths without invented values" do
    bytes = Base.decode16!("058000FFFFFFFF800080008000FFFFFFFFFFFFFFFFFFFFFF")
    assert byte_size(bytes) == 24
    <<5, t::signed-16, h::16, p::16, x::signed-16, y::signed-16, z::signed-16,
      battery::11, tx::5, movement::8, sequence::16, mac::48>> = bytes
    assert {t,h,p,x,y,z,battery,tx,movement,sequence,mac} ==
      {-32768,65535,65535,-32768,-32768,-32768,2047,31,255,65535,281474976710655}
  end

  test "Nx 1.0 is outside the inspected sibling requirement" do
    assert Version.match?("0.13.1", "~> 0.13.1")
    refute Version.match?("1.0.0", "~> 0.13.1")
  end
end
```

</details>

<details>
<summary>Specification integrity and adverse-input probes: check_specs.rb</summary>

<!-- probe: catalogue -->
```ruby
require "yaml"
require "date"
require "pathname"
require "uri"

def reject_duplicate_keys(node)
  if node.is_a?(Psych::Nodes::Mapping)
    keys = node.children.each_slice(2).map do |key, _|
      raise "non-scalar key" unless key.is_a?(Psych::Nodes::Scalar)
      key.value
    end
    raise "duplicate YAML key" unless keys.uniq == keys
  end
  (node.children || []).each { |child| reject_duplicate_keys(child) }
end

def validate_catalogue(source, root)
  reject_duplicate_keys(Psych.parse_stream(source))
  value = YAML.safe_load(source, permitted_classes: [Date], aliases: false)
  raise "wrong family/package" unless value.values_at("family", "package") == ["WTR", "wotex_tracker"]
  raise "wrong status" unless value["status"] == "target-contracts" &&
    value["implementation_status"] == "not-started" && value["executed_evidence"] == []
  contracts = value.fetch("contracts")
  ids = contracts.map { |c| c.fetch("id") }
  expected = (0..14).map { |n| "WTR.%02d" % n }
  raise "duplicate/missing contract" unless ids.sort == expected
  contracts.each do |contract|
    path = root.join("docs/specs", contract.fetch("file"))
    raise "missing spec" unless path.file?
    raise "wrong heading" unless path.read.lines.first.start_with?("# #{contract.fetch("id")} ")
    raise "unknown contract reference" unless (contract.fetch("depends_on") - ids - ["wotex"]).empty?
  end
  value.fetch("initial_profiles").each_value do |profile|
    raise "unsupported promotion" unless profile["implementation_status"] == "not-started" &&
      profile["current_evidence"] == "research" && profile["evidence_refs"] == []
  end
  contracts.size
end

root = Pathname.new(ARGV.fetch(0)).realpath
source = root.join("docs/specs/catalogue.yaml").read
count = validate_catalogue(source, root)
mutants = [
  [source + "\nfamily: WTR\n", "duplicate YAML key"],
  [source.sub("id: WTR.01", "id: WTR.00"), "duplicate/missing contract"],
  [source.sub("file: WTR.00-library-contract.md", "file: missing-spec.md"), "missing spec"],
  [source.sub("depends_on: [wotex]", "depends_on: [WTR.99]"), "unknown contract reference"],
  [source.sub("current_evidence: research", "current_evidence: hardware-qualified"), "unsupported promotion"]
]
mutants.each do |mutant, expected|
  rejected = false
  begin
    validate_catalogue(mutant, root)
  rescue RuntimeError => error
    raise "wrong rejection: #{error.message}" unless error.message == expected
    rejected = true
  end
  raise "adverse catalogue accepted" unless rejected
end

documents = [root.join("README.md")] + root.join("docs").glob("**/*.md")
links = 0
documents.each do |path|
  body = path.read.gsub(/\x60{3}.*?\x60{3}/m, "")
  body.scan(/!?\[[^\]]*\]\(([^)]+)\)/).flatten.each do |target|
    next if target.match?(/\A(?:https?:|mailto:|#)/)
    file = URI::DEFAULT_PARSER.unescape(target.split("#", 2).first)
    raise "broken local target #{path}: #{target}" unless path.dirname.join(file).exist?
    links += 1
  end
end
index = root.join("docs/specs/WTR-index.md").read
root.join("docs/specs").glob("WTR.*.md").each do |path|
  raise "unindexed spec #{path}" unless index.include?("(#{path.basename})")
end
puts "PASS: #{count} contracts, #{mutants.size} adverse catalogues rejected, #{documents.size} Markdown documents, #{links} local file links, complete spec index."
```

</details>
