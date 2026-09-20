defmodule Wotex.Tracker.Service.PassiveScannerTest do
  @moduledoc false

  use ExUnit.Case, async: false

  import Wotex.Tracker.Service.Fixtures

  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.Development.PassiveSimulator
  alias Wotex.Tracker.Service.{PassiveAdvertisement, PassiveIngress, PassiveScanner}

  @payload Base.decode16!("0512FC5394C37C0004FFFC040CAC364200CDCBB8334C884F")

  defmodule SlowAdapter do
    @behaviour Wotex.Tracker.Service.PassiveScanAdapter

    @impl true
    def init(owner), do: {:ok, owner}

    @impl true
    def next(owner) do
      send(owner, :adapter_started)
      Process.sleep(:infinity)
    end
  end

  defmodule FailingAdapter do
    @behaviour Wotex.Tracker.Service.PassiveScanAdapter

    @impl true
    def init(:raise), do: raise("private scanner init failure")
    def init(mode), do: {:ok, mode}

    @impl true
    def next(:raise), do: raise("private scanner read failure")
    def next(:throw), do: throw(:private_scanner_read_failure)
    def next(:invalid), do: :invalid
    def next(:error), do: {:error, :private_failure, :error}
  end

  defmodule IdleAdapter do
    @behaviour Wotex.Tracker.Service.PassiveScanAdapter

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def next(:idle), do: {:idle, :stop}
    def next(:stop), do: {:stop, :stop}
  end

  defmodule TerminatingAdapter do
    @behaviour Wotex.Tracker.Service.PassiveScanAdapter

    @impl true
    def init(owner), do: {:ok, owner}

    @impl true
    def next(owner), do: {:idle, owner}

    @impl true
    def terminate(reason, owner), do: send(owner, {:adapter_terminated, reason})
  end

  defmodule RaisingVia do
    def whereis_name(_), do: raise("private registry failure")
  end

  setup do
    context = service()

    ingress =
      start_supervised!(
        {PassiveIngress,
         service: context.service,
         token: context.admin,
         scope: context.scope,
         adapter: "development-passive-simulator"}
      )

    %{context: context, ingress: ingress}
  end

  test "a deterministic passive peer crosses the full Ruuvi import boundary", c do
    first = advertisement("simulated-capture-one", "random-address-one", c.context.now)
    second = advertisement("simulated-capture-two", "random-address-two", c.context.now + 1)

    scanner =
      start_supervised!(
        {PassiveScanner,
         adapter: {PassiveSimulator, [first, second]},
         ingress: c.ingress,
         interval_ms: 0,
         timeout_ms: 1_000}
      )

    eventually(fn -> PassiveScanner.status(scanner).lifecycle == :stopped end)

    assert %{
             lifecycle: :stopped,
             accepted: 2,
             duplicate: 0,
             rejected: 0,
             unknown: 0
           } = PassiveScanner.status(scanner)

    assert {:ok, %{"generation" => "2", "items" => observations}} = observations(c.context)
    assert length(observations) == 2

    for item <- observations do
      assert item["value"]["ingress"] == "ble"
      assert map_size(item["value"]) == 3
    end

    assert {:ok, %{"generation" => "2", "items" => resolutions}} = resolutions(c.context)
    assert Enum.all?(resolutions, &(&1["value"]["status"] == "resolved"))

    assert {:ok, %{"generation" => "2", "items" => states}} = states(c.context)

    for item <- states do
      assert Enum.any?(item["value"]["measurements"], fn measurement ->
               measurement["kind"] == "temperature" and measurement["value"]["value"] == 24.3
             end)
    end

    refute inspect(PassiveScanner.status(scanner)) =~ "random-address"
    refute inspect(:sys.get_status(c.ingress)) =~ c.context.admin
  end

  test "a retransmitted capture is reconciled without another generation", c do
    capture = advertisement("simulated-retransmission", "private-address", c.context.now)
    {:ok, admitted} = PassiveAdvertisement.new(capture)

    assert {:ok, %{disposition: :accepted, operation_id: operation}} =
             PassiveIngress.submit(c.ingress, admitted)

    assert {:ok, %{disposition: :duplicate, operation_id: ^operation}} =
             PassiveIngress.submit(c.ingress, admitted)

    assert {:ok, %{"generation" => "1", "items" => [_]}} = observations(c.context)
  end

  test "unknown and pre-commit outcomes stay distinct and never retry implicitly" do
    after_commit =
      service(fault: fn phase -> if phase == :after_commit, do: :abort, else: :ok end)

    after_ingress = start_ingress(after_commit, "after-commit-adapter")
    capture = advertisement("post-commit-capture", "private-address", after_commit.now)
    {:ok, admitted} = PassiveAdvertisement.new(capture)

    assert {:ok, %{disposition: :unknown}} = PassiveIngress.submit(after_ingress, admitted)
    assert {:ok, %{disposition: :duplicate}} = PassiveIngress.submit(after_ingress, admitted)

    before_commit =
      service(fault: fn phase -> if phase == :before_commit, do: :abort, else: :ok end)

    before_ingress = start_ingress(before_commit, "before-commit-adapter")
    before_capture = advertisement("pre-commit-capture", "private-address", before_commit.now)
    {:ok, before_admitted} = PassiveAdvertisement.new(before_capture)

    assert {:ok, %{disposition: :rejected}} =
             PassiveIngress.submit(before_ingress, before_admitted)

    unavailable_operation = service()
    operation_pid = spawn(fn -> store_peer(:operation_unavailable) end)
    failed_store = %{unavailable_operation.store | pid: operation_pid}
    failed_service = %{unavailable_operation.service | store: failed_store}
    failed = %{unavailable_operation | service: failed_service, store: failed_store}
    operation_ingress = start_ingress(failed, "operation-unavailable-adapter")

    operation_capture =
      advertisement("operation-unavailable", "private-address", unavailable_operation.now)

    assert {:ok, operation_admitted} = PassiveAdvertisement.new(operation_capture)

    assert {:ok, %{disposition: :unknown}} =
             PassiveIngress.submit(operation_ingress, operation_admitted)

    unavailable_snapshot = service()
    snapshot_pid = spawn(fn -> store_peer(:die_after_operation) end)
    snapshot_store = %{unavailable_snapshot.store | pid: snapshot_pid}
    snapshot_service = %{unavailable_snapshot.service | store: snapshot_store}
    snapshot_context = %{unavailable_snapshot | service: snapshot_service, store: snapshot_store}
    snapshot_ingress = start_ingress(snapshot_context, "snapshot-unavailable-adapter")

    snapshot_capture =
      advertisement("snapshot-unavailable", "private-address", unavailable_snapshot.now)

    assert {:ok, snapshot_admitted} = PassiveAdvertisement.new(snapshot_capture)

    assert {:ok, %{disposition: :unknown}} =
             PassiveIngress.submit(snapshot_ingress, snapshot_admitted)
  end

  test "invalid captures, credentials and service loss fail closed", c do
    capture = advertisement("invalid-capture", "private-address", c.context.now)
    {:ok, admitted} = PassiveAdvertisement.new(capture)

    invalid = [
      Map.put(capture, :payload, <<>>),
      Map.put(capture, :address_type, :forged),
      Map.put(capture, :rssi, -128),
      Map.put(capture, :manufacturer_id, 65_536),
      Map.put(capture, :provenance, %{}),
      Map.put(capture, :unknown, true),
      %{admitted | payload: <<>>},
      :invalid
    ]

    for value <- invalid do
      assert {:error, :invalid_advertisement} = PassiveIngress.submit(c.ingress, value)
    end

    rejected =
      start_supervised!(
        Supervisor.child_spec(
          {PassiveIngress,
           service: c.context.service,
           token: c.context.reader,
           scope: c.context.scope,
           adapter: "unauthorized-adapter"},
          id: :unauthorized_ingress
        )
      )

    assert {:ok, %{disposition: :rejected}} = PassiveIngress.submit(rejected, admitted)

    unavailable =
      start_supervised!(
        Supervisor.child_spec(
          {PassiveIngress,
           service: fn -> {:error, :offline} end,
           token: c.context.admin,
           scope: c.context.scope,
           adapter: "offline-adapter"},
          id: :offline_ingress
        )
      )

    assert {:ok, %{disposition: :rejected}} = PassiveIngress.submit(unavailable, admitted)
    assert {:ok, %{"generation" => "0", "items" => []}} = observations(c.context)

    provider =
      start_supervised!(
        Supervisor.child_spec(
          {PassiveIngress,
           service: fn -> {:ok, c.context.service} end,
           token: c.context.admin,
           scope: c.context.scope,
           adapter: "provider-adapter"},
          id: :provider_ingress
        )
      )

    assert {:ok, %{disposition: :accepted}} = PassiveIngress.submit(provider, admitted)

    for {id, service_provider} <- [
          {:raising_ingress, fn -> raise("private provider failure") end},
          {:throwing_ingress, fn -> throw(:private_provider_failure) end}
        ] do
      ingress =
        start_supervised!(
          Supervisor.child_spec(
            {PassiveIngress,
             service: service_provider,
             token: c.context.admin,
             scope: c.context.scope,
             adapter: Atom.to_string(id)},
            id: id
          )
        )

      assert {:ok, %{disposition: :rejected}} = PassiveIngress.submit(ingress, admitted)
    end

    assert {:ok, admitted} = PassiveAdvertisement.validate(admitted)
    assert {:error, :invalid_advertisement} = PassiveAdvertisement.validate(:invalid)
    assert {:error, :invalid_advertisement} = PassiveAdvertisement.new(:invalid)

    assert {:ok, _} =
             capture
             |> put_in([:provenance, "sequence"], 1)
             |> put_in([:provenance, "verified"], false)
             |> PassiveAdvertisement.new()

    assert {:error, :invalid_advertisement} =
             capture
             |> Map.put(:provenance, :invalid)
             |> PassiveAdvertisement.new()

    assert {:error, :invalid_advertisement} =
             capture
             |> put_in([:provenance, "scenario"], nil)
             |> PassiveAdvertisement.new()

    assert {:ok, queue} = PassiveSimulator.init([admitted])
    assert {{:value, ^admitted}, _} = :queue.out(queue)
    assert {:error, :invalid_scenario} = PassiveSimulator.init([%{invalid: true}])
    assert {:ok, %{"generation" => "1", "items" => [_]}} = observations(c.context)
  end

  test "adapter errors are bounded and a blocked adapter is killed with its owner", c do
    Process.flag(:trap_exit, true)

    recovering =
      start_supervised!(
        Supervisor.child_spec(
          {PassiveScanner,
           adapter: {FailingAdapter, :error},
           ingress: c.ingress,
           interval_ms: 100,
           timeout_ms: 100},
          id: :recovering_scanner
        )
      )

    eventually(fn -> PassiveScanner.status(recovering).rejected >= 1 end)
    assert Process.alive?(recovering)

    assert {:error, :adapter_unavailable} =
             PassiveScanner.start_link(
               adapter: {FailingAdapter, :raise},
               ingress: c.ingress,
               interval_ms: 0,
               timeout_ms: 50
             )

    {:ok, invalid} =
      PassiveScanner.start_link(
        adapter: {FailingAdapter, :invalid},
        ingress: c.ingress,
        interval_ms: 0,
        timeout_ms: 50
      )

    assert_receive {:EXIT, ^invalid, :adapter_unavailable}, 1_000

    {:ok, thrown} =
      PassiveScanner.start_link(
        adapter: {FailingAdapter, :throw},
        ingress: c.ingress,
        interval_ms: 0,
        timeout_ms: 50
      )

    assert_receive {:EXIT, ^thrown, :adapter_unavailable}, 1_000

    {:ok, blocked} =
      PassiveScanner.start_link(
        adapter: {SlowAdapter, self()},
        ingress: c.ingress,
        interval_ms: 0,
        timeout_ms: 50
      )

    assert_receive :adapter_started
    assert_receive {:EXIT, ^blocked, :adapter_unavailable}, 1_000
  end

  test "idle adapters, stopped polls, termination and unavailable ingress remain bounded", c do
    idle =
      start_supervised!(
        {PassiveScanner,
         adapter: {IdleAdapter, :idle}, ingress: c.ingress, interval_ms: 0, timeout_ms: 100}
      )

    eventually(fn -> PassiveScanner.status(idle).lifecycle == :stopped end)
    send(idle, :poll)
    send(idle, {:EXIT, self(), :synthetic})
    assert PassiveScanner.status(idle).lifecycle == :stopped

    terminating =
      start_supervised!(
        Supervisor.child_spec(
          {PassiveScanner,
           adapter: {TerminatingAdapter, self()},
           ingress: c.ingress,
           interval_ms: 1_000,
           timeout_ms: 100},
          id: :terminating_scanner,
          restart: :temporary
        )
      )

    GenServer.stop(terminating, :normal)
    assert_receive {:adapter_terminated, :normal}, 1_000
    assert :ok = PassiveScanner.terminate(:normal, :invalid)

    missing =
      start_supervised!(
        Supervisor.child_spec(
          {PassiveScanner,
           adapter:
             {PassiveSimulator, [advertisement("missing-ingress", "private", c.context.now)]},
           ingress: :missing_passive_ingress,
           interval_ms: 0,
           timeout_ms: 100},
          id: :missing_ingress_scanner
        )
      )

    eventually(fn -> PassiveScanner.status(missing).lifecycle == :stopped end)
    assert PassiveScanner.status(missing).unknown == 1

    raising =
      start_supervised!(
        Supervisor.child_spec(
          {PassiveScanner,
           adapter:
             {PassiveSimulator, [advertisement("raising-ingress", "private", c.context.now)]},
           ingress: {:via, RaisingVia, :missing},
           interval_ms: 0,
           timeout_ms: 100},
          id: :raising_ingress_scanner
        )
      )

    eventually(fn -> PassiveScanner.status(raising).lifecycle == :stopped end)
    assert PassiveScanner.status(raising).unknown == 1

    for ingress <- [{:global, :missing}, {:via, Registry, :missing}] do
      assert {:ok, scanner} =
               PassiveScanner.start_link(
                 adapter: {IdleAdapter, :stop},
                 ingress: ingress,
                 interval_ms: 0,
                 timeout_ms: 100
               )

      eventually(fn -> PassiveScanner.status(scanner).lifecycle == :stopped end)
      GenServer.stop(scanner)
    end
  end

  test "scanner and ingress configuration are closed", c do
    Process.flag(:trap_exit, true)

    base_ingress = [
      service: c.context.service,
      token: c.context.admin,
      scope: c.context.scope,
      adapter: "configured-adapter"
    ]

    for options <- [
          [],
          Keyword.delete(base_ingress, :service),
          Keyword.put(base_ingress, :service, :invalid),
          Keyword.put(base_ingress, :token, "invalid"),
          Keyword.put(base_ingress, :scope, ""),
          Keyword.put(base_ingress, :adapter, ""),
          Keyword.put(base_ingress, :maximum_retries, 4),
          base_ingress ++ [unknown: true],
          base_ingress ++ [scope: "other"]
        ] do
      assert {:error, :invalid_configuration} = PassiveIngress.start_link(options)
    end

    assert {:error, :invalid_configuration} = PassiveIngress.start_link(:invalid)

    base_scanner = [
      adapter: {PassiveSimulator, [advertisement("one", "address", c.context.now)]},
      ingress: c.ingress
    ]

    for options <- [
          [],
          Keyword.put(base_scanner, :adapter, {String, []}),
          Keyword.put(base_scanner, :adapter, :invalid),
          Keyword.put(base_scanner, :ingress, nil),
          Keyword.put(base_scanner, :ingress, []),
          Keyword.put(base_scanner, :interval_ms, 60_001),
          Keyword.put(base_scanner, :timeout_ms, 0),
          base_scanner ++ [unknown: true],
          base_scanner ++ [ingress: c.ingress]
        ] do
      assert {:error, :invalid_configuration} = PassiveScanner.start_link(options)
    end

    assert {:error, :invalid_configuration} = PassiveScanner.start_link(:invalid)

    assert {:error, :adapter_unavailable} =
             PassiveScanner.start_link(adapter: {FailingAdapter, :raise}, ingress: c.ingress)

    assert {:error, :adapter_unavailable} =
             PassiveScanner.start_link(adapter: {PassiveSimulator, []}, ingress: c.ingress)
  end

  defp advertisement(id, address, observed_at) do
    %{
      id: id,
      observed_at: observed_at,
      receiver: "development-macos",
      address: address,
      address_type: :random_private_resolvable,
      manufacturer_id: 1_177,
      payload: @payload,
      rssi: -42,
      provenance: %{"evidence_class" => "simulator", "scenario" => "ruuvi-raw-v2"}
    }
  end

  defp observations(context) do
    Service.list(
      context.service,
      context.admin,
      context.scope,
      "observations",
      %{"limit" => 10},
      context.now + 10
    )
  end

  defp start_ingress(context, adapter) do
    start_supervised!(
      Supervisor.child_spec(
        {PassiveIngress,
         service: context.service, token: context.admin, scope: context.scope, adapter: adapter},
        id: make_ref(),
        restart: :temporary
      )
    )
  end

  defp store_peer(mode) do
    receive do
      {:"$gen_call", from, {:authorized, _access, _permission, _activity, _now}} ->
        GenServer.reply(from, :ok)
        store_peer(mode)

      {:"$gen_call", from, {:operation, _scope, _principal, _operation, _now}} ->
        case mode do
          :operation_unavailable ->
            GenServer.reply(from, {:error, :unavailable})
            store_peer(mode)

          :die_after_operation ->
            GenServer.reply(from, {:error, :not_found})
        end
    end
  end

  defp states(context) do
    Service.list(
      context.service,
      context.admin,
      context.scope,
      "state",
      %{"limit" => 10},
      context.now + 10
    )
  end

  defp resolutions(context) do
    Service.list(
      context.service,
      context.admin,
      context.scope,
      "resolutions",
      %{"limit" => 10},
      context.now + 10
    )
  end

  defp eventually(function, attempts \\ 100)
  defp eventually(function, 0), do: assert(function.())

  defp eventually(function, attempts) do
    if function.() do
      :ok
    else
      Process.sleep(10)
      eventually(function, attempts - 1)
    end
  end
end
