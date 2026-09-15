# Production archive consumer: no repository source imports and no host packages.
alias Wotex.Tracker.Service
alias Wotex.Tracker.Service.{Credentials, Cursor, Identifier, Projection, Store, Update}

[] = Application.spec(:wotex_tracker_service, :mod)

for module <- [Phoenix, Nerves, Nx, Wotex.Runtime, Wotex.Directory] do
  false = Code.ensure_loaded?(module)
end

directory = Path.expand("store")
File.mkdir!(directory)
File.chmod!(directory, 0o700)

token = Credentials.generate_token()
{:ok, digest} = Credentials.token_digest(token)

{:ok, credentials} =
  Credentials.new(%{
    instance_id: "archive-instance",
    secret_key: :crypto.strong_rand_bytes(32),
    entries: [
      %{
        id: "archive-credential",
        principal: "consumer",
        token_sha256: digest,
        grants: %{"archive" => ~w(read raw ingest enroll admin)},
        expires_at: 1_700_000_001_000
      }
    ]
  })

{:ok, access} =
  Credentials.authenticate(credentials, token, "archive", "ingest", 1_700_000_000_000)

binding = %{
  instance: Credentials.instance_id(credentials),
  principal: "consumer",
  scope: "archive",
  purpose: "page"
}

cursor_data = %{
  "kind" => "observations",
  "generation" => "1",
  "after" => "private-id",
  "limit" => 10
}

key = Credentials.derive_key(credentials, :cursor)
{:ok, cursor} = Cursor.issue(key, binding, cursor_data, 1_700_000_000_000)
{:ok, ^cursor_data} = Cursor.open(key, binding, cursor, 1_700_000_000_000)

{:error, :invalid_cursor} =
  Cursor.open(key, %{binding | scope: "other"}, cursor, 1_700_000_000_000)

%{"type" => "wide_integer", "value" => "9007199254740993"} =
  Projection.scalar(9_007_199_254_740_993)

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
    authority: access,
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
{:ok, pid} = Store.start_link(directory: directory, credentials: credentials)
store = Store.handle(pid)
{:ok, result} = Store.mutate(store, update)
"committed" = result["outcome"]
{:ok, ^result} = Store.mutate(store, update)
{:ok, %{"sqlite" => "3.53.4"}} = Store.readiness(store)
GenServer.stop(pid)
{:ok, pid} = Store.start_link(directory: directory, credentials: credentials)
store = Store.handle(pid)
{:ok, ^result} = Store.operation(store, "archive", "consumer", "import-1", update.now)

{:ok, %{"items" => [%{"value" => document}]}} =
  Store.authorized_snapshot(
    store,
    access,
    "raw",
    %{
      scope: "archive",
      kind: "observations",
      generation: "1",
      after: "",
      limit: 10
    },
    update.now
  )

{:ok, restored} = Wotex.Tracker.Observation.from_map(document)
true = restored === observation

{:ok, %{"items" => [_]}} =
  Store.authorized_events(store, access, %{
    scope: "archive",
    after: "0",
    limit: 10,
    now: update.now
  })

{:ok, service} =
  Service.new(%{store: store, credentials: credentials, base_url: "http://127.0.0.1:43210"})

{:ok, document} =
  Wotex.Tracker.Observation.to_map(%{
    observation
    | id: "ruuvi-fixture",
      ingress: "ble",
      transport: %{"manufacturer_id" => 1177},
      payload: {:bytes, Base.decode16!("0512FC5394C37C0004FFFC040CAC364200CDCBB8334C884F")}
  })

{:ok, imported} =
  Service.submit(
    service,
    token,
    "archive",
    Identifier.uuid(),
    %{
      "observation" => document,
      "expected_generation" => "1"
    },
    update.now
  )

{:ok, enrolled} =
  Service.enroll(
    service,
    token,
    "archive",
    Identifier.uuid(),
    %{
      "observation_id" => imported["data"]["observation_id"],
      "title" => "Archive sensor",
      "owner_confirmed" => true,
      "expected_generation" => "2"
    },
    update.now
  )

thing = enrolled["data"]["thing_id"]
operation = Identifier.uuid()
request = %{"thing_id" => thing, "expected_generation" => "3"}
{:ok, receipt} = Service.materialize(service, token, "archive", operation, request, update.now)
{:ok, %{"value" => td}} = Service.get(service, token, "archive", "things", thing, update.now)
{:ok, _} = Wotex.ThingDescription.from_map(td)
^thing = td["id"]
GenServer.stop(pid)
{:ok, pid} = Store.start_link(directory: directory, credentials: credentials)
store = Store.handle(pid)
service = %{service | store: store}
{:ok, ^receipt} = Service.materialize(service, token, "archive", operation, request, update.now)
{:ok, %{"value" => ^td}} = Service.get(service, token, "archive", "things", thing, update.now)

{:ok, revoke} =
  Update.new(%{
    Map.from_struct(update)
    | operation_id: "revoke",
      expected_generation: "4",
      observation: nil,
      request: %{"operation" => "revoke"},
      records: [%{kind: "access", id: "archive-credential", value: %{"revoked" => true}}],
      events: [%{"type" => "access.revoked", "data" => %{}}]
  })

{:ok, %{"generation" => "5"}} = Store.mutate(store, revoke)
{:error, :unauthorized} = Store.authorized(store, access, "read", update.now)
{:error, :unauthorized} = Store.mutate(store, update)

GenServer.stop(pid)
File.rm_rf!(directory)
retained = Process.list() |> MapSet.new() |> MapSet.difference(before_processes) |> MapSet.size()
0 = retained

IO.puts(
  "SERVICE_COHORT_PASS durable_restart=true native_types=true revoked_access_denied=true encrypted_cursor=true authenticated_enrollment_materialisation=true retained_new_processes=#{retained}"
)
