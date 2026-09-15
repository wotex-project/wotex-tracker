# Production archive consumer: no repository source imports and no host packages.
alias Wotex.Tracker.Service
alias Wotex.Tracker.Service.{Codec, Credentials, Cursor, Identifier, Projection, Store, Update}
alias Wotex.Binding.HTTP
alias Wotex.Runtime.{ConsumedThing, Context, Result}
alias Wotex.Tracker.Service.HTTP.{LoopbackClient, Server}

defmodule ArchivePeerCredentials do
  @moduledoc false
  @behaviour Wotex.Runtime.Credentials
  @impl true
  def resolve(%{names: ["bearer"]}, _, _, table) do
    [{:token, token}] = :ets.lookup(table, :token)
    {:ok, token}
  end
end

[] = Application.spec(:wotex_tracker_service, :mod)

for module <- [Phoenix, Nerves, Nx, Wotex.Directory] do
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
http_directory = Path.join(directory, "http")
File.mkdir!(http_directory)
File.chmod!(http_directory, 0o700)
reader = Credentials.generate_token()
{:ok, reader_digest} = Credentials.token_digest(reader)
now = update.now

{:ok, http_credentials} =
  Credentials.new(%{
    instance_id: "archive-http",
    secret_key: :crypto.strong_rand_bytes(32),
    entries: [
      %{
        id: "admin",
        principal: "operator",
        token_sha256: digest,
        grants: %{"workshop" => ~w(read raw ingest enroll admin interact)},
        expires_at: now + 1000
      },
      %{
        id: "reader",
        principal: "reader",
        token_sha256: reader_digest,
        grants: %{"workshop" => ~w(read)},
        expires_at: now + 1000
      }
    ]
  })

{:ok, server} =
  Server.start_link(
    directory: http_directory,
    credentials: http_credentials,
    ip: {127, 0, 0, 1},
    port: 0,
    exposure: :loopback,
    public_origin: :listener,
    clock: fn -> now end,
    poll_interval: 25
  )

{:ok, {_, port}} = Server.listener_info(server)
descriptor = Path.join(directory, "http-client.json")

File.write!(
  descriptor,
  Codec.encode!(%{
    "url" => "http://127.0.0.1:#{port}",
    "token" => token,
    "reader" => reader,
    "scope" => "workshop",
    "now" => now
  })
)

File.chmod!(descriptor, 0o600)

{output, 0} =
  System.cmd(
    System.fetch_env!("WTR_HTTP_PYTHON"),
    [System.fetch_env!("WTR_HTTP_CONSUMER"), descriptor],
    stderr_to_stdout: true
  )

true = String.contains?(output, "HTTP_CONSUMER_PASS")
{:ok, store_pid} = Server.child(server, :store)
origin = "http://127.0.0.1:#{port}"

{:ok, service} =
  Service.new(%{store: Store.handle(store_pid), credentials: http_credentials, base_url: origin})

{:ok, %{"items" => [%{"value" => document}]}} =
  Service.list(service, token, "workshop", "things", %{}, now)

{:ok, td} = Wotex.ThingDescription.from_map(document)
{:ok, client} = LoopbackClient.new(origin, "workshop")
{:ok, binding} = HTTP.config(client: {LoopbackClient, client})
{:ok, profile} = HTTP.profile()
table = :ets.new(:archive_peer_credentials, [:private])
:ets.insert(table, {:token, token})

{:ok, consumed} =
  ConsumedThing.new(td,
    profiles: [profile],
    transports: %{http: HTTP.transport(binding)},
    credentials: {ArchivePeerCredentials, table}
  )

false = :erlang.term_to_binary(consumed) =~ token

context =
  Context.new!(request_id: "archive-peer", deadline: System.monotonic_time(:millisecond) + 3000)

{:ok, %Result{status: :ok, operation: :readproperty, payload: 24.3}} =
  ConsumedThing.read_property(consumed, "temperature", context)

{:ok, %Result{status: :ok, operation: :readproperty, payload: 100_044}} =
  ConsumedThing.read_property(consumed, "pressure", context)

:ets.delete(table)
Supervisor.stop(server)
File.rm_rf!(directory)
retained = Process.list() |> MapSet.new() |> MapSet.difference(before_processes) |> MapSet.size()
0 = retained

IO.puts(
  "SERVICE_COHORT_PASS durable_restart=true native_types=true revoked_access_denied=true encrypted_cursor=true authenticated_enrollment_materialisation=true independent_http_sse=true actual_runtime_http_peer=true retained_new_processes=#{retained}"
)
