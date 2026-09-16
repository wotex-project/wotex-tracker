# Production archive consumer: no repository source imports and no host packages.
alias Wotex.Tracker.Service

alias Wotex.Tracker.{
  Evidence,
  EvidenceBundle,
  HeartbeatTransition,
  PolicyFact,
  TransportCandidate,
  TransportDegradation,
  TransportPolicy
}

alias Wotex.Tracker.Service.{
  Codec,
  Credentials,
  Cursor,
  ForwardItem,
  Identifier,
  Projection,
  RuleTransition,
  Store,
  Update
}

alias Wotex.Binding.HTTP
alias Wotex.Runtime.{ConsumedThing, Context, Result, Subscription}
alias Wotex.Tracker.Service.HTTP.{LoopbackClient, Server}

defmodule ArchivePeerCredentials do
  @moduledoc false
  use GenServer
  @behaviour Wotex.Runtime.Credentials
  def start_link(token), do: GenServer.start_link(__MODULE__, token)
  @impl true
  def init(token), do: {:ok, token}
  @impl true
  def handle_call(:resolve, _, token), do: {:reply, {:ok, token}, token}
  @impl true
  def format_status(status), do: Map.put(status, :state, :redacted)
  @impl Wotex.Runtime.Credentials
  def resolve(%{names: ["bearer"]}, _, _, vault), do: GenServer.call(vault, :resolve)
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
{:ok, %{"schema" => "3", "sqlite" => "3.53.4"}} = Store.readiness(store)

transport_fact = fn id, predicate, kind ->
  {:ok, evidence} =
    Evidence.new(%{
      id: id,
      kind: kind,
      claim: %{
        "schema" => "wtr.policy-fact.v1",
        "predicate" => predicate,
        "status" => "true",
        "policy_revision" => "archive-facts-v1",
        "reason" => "archive_fixture"
      },
      source_observation_ids: [observation.id],
      evidence_ids: [],
      profile: {"archive-transport", "1"},
      decoder: {"archive-transport", "1"},
      confidence: :exact,
      reasons: ["archive_fixture"],
      association_id: nil
    })

  {:ok, bundle} = EvidenceBundle.new([observation], [evidence])
  {:ok, fact} = PolicyFact.new(evidence.id, bundle)
  fact
end

{:ok, route} =
  TransportCandidate.new(%{
    id: "lorawan",
    bearer: "lorawan-eu868",
    application_protocol: "fixture-protocol",
    capability:
      transport_fact.(
        "archive-route-capability",
        TransportCandidate.capability_predicate("lorawan"),
        :capability
      ),
    connectivity:
      transport_fact.(
        "archive-route-connectivity",
        TransportCandidate.connectivity_predicate("lorawan"),
        :transport
      ),
    cost_class: 10,
    power_class: 10,
    acknowledgement_layers: []
  })

{:ok, transport_policy} =
  TransportPolicy.new(%{
    id: "archive-transport",
    revision: "archive-transport-v1",
    fact_policy_revision: "archive-facts-v1",
    ordinary_order: ["lorawan"],
    critical_order: ["lorawan"],
    maximum_fact_age_ms: 1_000,
    future_skew_ms: 0,
    ordinary_max_cost_class: 100,
    critical_max_cost_class: 100,
    ordinary_max_power_class: 100,
    critical_max_power_class: 100,
    ordinary_acknowledgement: :none,
    critical_acknowledgement: :none,
    ordinary_no_route: :store_and_retry,
    critical_no_route: :unavailable
  })

transport_request = %{
  id: "archive-route-request",
  severity: :critical,
  purpose: :event,
  maximum_cost_class: 100,
  maximum_power_class: 100,
  acknowledgement: nil
}

{:ok, transport_health_policy} =
  TransportDegradation.new(%{
    id: "archive-transport-health",
    revision: "archive-health-v1",
    transport_policy: transport_policy,
    healthy_candidate_ids: ["lorawan"],
    maximum_decision_age_ms: 1_000,
    future_skew_ms: 0
  })

{:ok, healthy_decision} =
  TransportPolicy.select([route], transport_request, transport_policy, update.now)

{:ok, healthy_result} =
  TransportDegradation.evaluate(
    nil,
    healthy_decision,
    transport_health_policy,
    :live,
    update.now
  )

{:ok, healthy_transition} = RuleTransition.new("archive-rules", nil, healthy_result)

{:ok, %{"generation" => "1", "event_disposition" => "none"}} =
  Store.commit_rule(store, healthy_transition)

{:ok, heartbeat_policy} =
  HeartbeatTransition.new(%{
    id: "archive-heartbeat",
    revision: "archive-heartbeat-v1",
    maximum_silence_ms: 10,
    future_skew_ms: 0
  })

{:ok, heartbeat_result} =
  HeartbeatTransition.evaluate(nil, observation, heartbeat_policy, :live, update.now)

{:ok, heartbeat_transition} =
  RuleTransition.new("archive-heartbeat", nil, heartbeat_result)

{:ok, %{"generation" => "1", "event_disposition" => "none"}} =
  Store.commit_rule(store, heartbeat_transition)

{:ok, forward_item} =
  ForwardItem.new(%{
    scope: "archive",
    id: "archive-forward",
    candidate_id: "cellular",
    bearer: "lte-m",
    application_protocol: "fixture-protocol",
    payload: %{"event" => "alarm"},
    source: :reliable,
    admitted_at: update.now,
    required_acknowledgement: :durable_admission
  })

{:ok, %{"status" => "pending"}} = Store.enqueue_forward(store, forward_item)
GenServer.stop(pid)
{:ok, pid} = Store.start_link(directory: directory, credentials: credentials)
store = Store.handle(pid)
{:ok, ^result} = Store.operation(store, "archive", "consumer", "import-1", update.now)

{:ok, durable_health} =
  Store.rule_state(
    store,
    "archive-rules",
    "transport_degradation",
    transport_health_policy.id
  )

{:ok, restored_health} = TransportDegradation.state_from_map(durable_health["state"])
true = restored_health === healthy_result["state"]

{:ok, unavailable_decision} =
  TransportPolicy.select(
    [],
    %{transport_request | id: "archive-route-unavailable"},
    transport_policy,
    update.now + 1
  )

{:ok, degraded_result} =
  TransportDegradation.evaluate(
    restored_health,
    unavailable_decision,
    transport_health_policy,
    :replay,
    update.now + 1
  )

{:ok, degraded_transition} =
  RuleTransition.new("archive-rules", restored_health, degraded_result)

{:ok, %{"generation" => "2", "event_disposition" => "recorded"} = degraded_receipt} =
  Store.commit_rule(store, degraded_transition)

{:ok, %{"disposition" => "duplicate", "generation" => "2"}} =
  Store.commit_rule(store, degraded_transition)

{:ok,
 %{
   "event" => %{"kind" => "transport.degraded"},
   "mode" => "replay",
   "physical_action_dispatch" => "prohibited"
 }} = Store.rule_event(store, "archive-rules", degraded_receipt["event_id"])

{:ok, durable_heartbeat} =
  Store.rule_state(store, "archive-heartbeat", "heartbeat", heartbeat_policy.id)

{:ok, restored_heartbeat} =
  HeartbeatTransition.state_from_map(durable_heartbeat["state"])

true = restored_heartbeat === heartbeat_result["state"]

{:ok, overdue_result} =
  HeartbeatTransition.evaluate(
    restored_heartbeat,
    nil,
    heartbeat_policy,
    :replay,
    restored_heartbeat.due_at
  )

{:ok, overdue_transition} =
  RuleTransition.new("archive-heartbeat", restored_heartbeat, overdue_result)

{:ok, %{"generation" => "2", "event_disposition" => "recorded"} = overdue_receipt} =
  Store.commit_rule(store, overdue_transition)

{:ok, %{"disposition" => "duplicate", "generation" => "2"}} =
  Store.commit_rule(store, overdue_transition)

{:ok,
 %{
   "event" => %{"kind" => "heartbeat.overdue"},
   "mode" => "replay",
   "physical_action_dispatch" => "prohibited"
 }} = Store.rule_event(store, "archive-heartbeat", overdue_receipt["event_id"])

{:ok, %{"status" => "pending"}} =
  Store.forward_status(store, "archive", forward_item.id)

{:ok, %{"items" => [%{"id" => "archive-forward", "attempt" => 1}]}} =
  Store.claim_forward(store, "archive", update.now, 1, 1_000)

{:ok, %{"status" => "delivered", "completion" => %{"layer" => "durable_admission"}}} =
  Store.complete_forward(
    store,
    "archive",
    forward_item.id,
    forward_item.identity,
    %{
      status: :acknowledged,
      layer: :durable_admission,
      at: update.now + 1,
      reference: "archive-server-admission"
    }
  )

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

later_document = %{document | "id" => "later-ruuvi-fixture"}

{:ok, later} =
  Service.submit(
    service,
    token,
    "archive",
    Identifier.uuid(),
    %{"observation" => later_document, "expected_generation" => "4"},
    update.now
  )

association_operation = Identifier.uuid()

association_request = %{
  "thing_id" => thing,
  "observation_id" => later["data"]["observation_id"],
  "owner_confirmed" => true,
  "expected_generation" => "5"
}

{:ok, associated} =
  Service.associate(
    service,
    token,
    "archive",
    association_operation,
    association_request,
    update.now
  )

{:ok, ^associated} =
  Service.associate(
    service,
    token,
    "archive",
    association_operation,
    association_request,
    update.now
  )

{:ok, %{"generation" => "7"}} =
  Service.materialize(
    service,
    token,
    "archive",
    Identifier.uuid(),
    %{"thing_id" => thing, "expected_generation" => "6"},
    update.now
  )

{:ok, history} = Service.history(service, token, "archive", "enrollments", thing, %{}, update.now)
["3", "6"] = Enum.map(history["items"], & &1["generation"])

{:ok, revoke} =
  Update.new(%{
    Map.from_struct(update)
    | operation_id: "revoke",
      expected_generation: "7",
      observation: nil,
      request: %{"operation" => "revoke"},
      records: [%{kind: "access", id: "archive-credential", value: %{"revoked" => true}}],
      events: [%{"type" => "access.revoked", "data" => %{}}]
  })

{:ok, %{"generation" => "8"}} = Store.mutate(store, revoke)
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
{:ok, vault} = ArchivePeerCredentials.start_link(token)

{:ok, consumed} =
  ConsumedThing.new(td,
    profiles: [profile],
    transports: %{http: HTTP.transport(binding)},
    credentials: {ArchivePeerCredentials, vault}
  )

false = :erlang.term_to_binary(consumed) =~ token

context =
  Context.new!(request_id: "archive-peer", deadline: System.monotonic_time(:millisecond) + 3000)

{:ok, %Result{status: :ok, operation: :readproperty, payload: 24.3}} =
  ConsumedThing.read_property(consumed, "temperature", context)

{:ok, %Result{status: :ok, operation: :readproperty, payload: 100_044}} =
  ConsumedThing.read_property(consumed, "pressure", context)

{:ok, subscriptions} = Supervisor.start_link([], strategy: :one_for_one)

peers =
  for {name, expected} <- [{"temperature", 24.3}, {"pressure", 100_044}] do
    request_id = "observe-" <> name

    stream_context =
      Context.new!(request_id: request_id, deadline: System.monotonic_time(:millisecond) + 3000)

    {:ok, spec} =
      ConsumedThing.observation_child_spec(consumed, name, stream_context,
        id: name,
        receiver: self(),
        max_queue_length: 32,
        overflow: :stop
      )

    {:ok, subscription} =
      Supervisor.start_child(subscriptions, Supervisor.child_spec(spec, restart: :temporary))

    receive do
      {:wotex_runtime, ^name, {:ok, ^expected, meta}} ->
        :observeproperty = meta.operation
        true = String.starts_with?(meta.event, "property:snapshot:")
    after
      2000 -> raise "archive Property subscription did not deliver"
    end

    {LoopbackClient, {_, {connection, _}, _, _}, _, _} =
      subscription |> :sys.get_state() |> Map.fetch!(:handle) |> HTTP.Subscription.unwrap()

    false = :erlang.term_to_binary(:sys.get_state(connection)) =~ token
    {subscription, connection}
  end

[{first, first_connection}, {second, second_connection}] = peers
first_monitor = Process.monitor(first_connection)
:ok = Subscription.stop(first)

receive do
  {:DOWN, ^first_monitor, :process, ^first_connection, _} -> :ok
after
  1000 -> raise "first archive subscription leaked"
end

true = Process.alive?(second_connection)
second_monitor = Process.monitor(second_connection)
:ok = Subscription.stop(second)

receive do
  {:DOWN, ^second_monitor, :process, ^second_connection, _} -> :ok
after
  1000 -> raise "second archive subscription leaked"
end

Supervisor.stop(subscriptions)
GenServer.stop(vault)
Supervisor.stop(server)
File.rm_rf!(directory)
retained = Process.list() |> MapSet.new() |> MapSet.difference(before_processes) |> MapSet.size()
0 = retained

IO.puts(
  "SERVICE_COHORT_PASS durable_restart=true durable_store_forward=true atomic_transport_health=true atomic_heartbeat=true native_types=true revoked_access_denied=true encrypted_cursor=true authenticated_enrollment_materialisation=true explicit_association=true independent_http_sse=true actual_runtime_http_peer=true actual_runtime_sse=true retained_new_processes=#{retained}"
)
