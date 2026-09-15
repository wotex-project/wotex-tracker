# Production archive consumer: no repository source imports and no host packages.
alias Wotex.Tracker.Service.{Store, Update}

[] = Application.spec(:wotex_tracker_service, :mod)

for module <- [Phoenix, Nerves, Nx, Wotex.Runtime, Wotex.Directory] do
  false = Code.ensure_loaded?(module)
end

directory = Path.expand("store")
File.mkdir!(directory)
File.chmod!(directory, 0o700)

{:ok, observation} =
  Wotex.Tracker.observation(%{
    id: "archive-observation",
    observed_at: 1_700_000_000_000,
    ingress: "imported",
    source: %{"number" => 1, "float" => 1.0, "wide" => 9_007_199_254_740_993},
    addressing: %{},
    radio: %{},
    transport: %{},
    provenance: %{},
    payload: {:bytes, <<0, 255>>}
  })

{:ok, update} =
  Update.new(%{
    principal: "consumer",
    scope: "archive",
    operation_id: "import-1",
    expected_generation: "0",
    request: %{"operation" => "import"},
    now: 1_700_000_000_000,
    observation: observation,
    records: [
      %{kind: "state", id: "sample", value: %{"zero" => 0, "missing" => nil, "false" => false}}
    ],
    events: [%{"type" => "observation.admitted", "data" => %{"id" => "archive-observation"}}],
    publication: nil
  })

before_processes = MapSet.new(Process.list())
{:ok, pid} = Store.start_link(directory: directory)
store = Store.handle(pid)
{:ok, result} = Store.mutate(store, update)
"committed" = result["outcome"]
{:ok, ^result} = Store.mutate(store, update)
{:ok, %{"sqlite" => "3.53.4"}} = Store.readiness(store)
GenServer.stop(pid)
{:ok, pid} = Store.start_link(directory: directory)
store = Store.handle(pid)
{:ok, ^result} = Store.operation(store, "archive", "consumer", "import-1", update.now)

{:ok, %{"items" => [%{"value" => document}]}} =
  Store.snapshot(store, %{
    scope: "archive",
    kind: "observations",
    generation: "1",
    after: "",
    limit: 10
  })

{:ok, restored} = Wotex.Tracker.Observation.from_map(document)
true = restored === observation

{:ok, %{"items" => [_]}} =
  Store.events(store, %{scope: "archive", after: "0", limit: 10, now: update.now})

GenServer.stop(pid)
File.rm_rf!(directory)
retained = Process.list() |> MapSet.new() |> MapSet.difference(before_processes) |> MapSet.size()
0 = retained

IO.puts(
  "SERVICE_COHORT_PASS durable_restart=true native_types=true retained_new_processes=#{retained}"
)
