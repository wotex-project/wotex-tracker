defmodule Wotex.Tracker.Service.ActiveProbeTest do
  use ExUnit.Case, async: true

  import Wotex.Tracker.Service.Fixtures

  alias Wotex.BLE
  alias Wotex.BLE.Error, as: BLEError
  alias Wotex.Tracker.{Catalogue, DeviceProfile, Observation, Resolution}
  alias Wotex.Tracker.Service

  alias Wotex.Tracker.Service.{
    ActiveProbe,
    BLEProbeAdapter,
    Identifier
  }

  defmodule Adapter do
    @behaviour Wotex.Tracker.Service.ActiveProbeAdapter

    @impl true
    def read({owner, result}, request, timeout_ms) do
      send(owner, {:probe_adapter, self(), request, timeout_ms})

      case result do
        :raise -> raise "private adapter failure"
        {:throw, reason} -> throw(reason)
        result -> result
      end
    end
  end

  defmodule BlockingAdapter do
    @behaviour Wotex.Tracker.Service.ActiveProbeAdapter

    @impl true
    def read(owner, request, timeout_ms) do
      send(owner, {:blocking_probe, self(), request, timeout_ms})

      receive do
        {:release, result} -> result
      end
    end
  end

  defmodule BLEClient do
    @behaviour Wotex.BLE.Client

    @impl true
    def connect(options) do
      {:ok,
       %{
         owner: Keyword.fetch!(options, :owner),
         result: Keyword.fetch!(options, :result),
         secret: "private-peer-handle"
       }}
    end

    @impl true
    def request(handle, message, timeout_ms) do
      send(handle.owner, {:ble_read, message, timeout_ms})
      handle.result
    end

    @impl true
    def disconnect(_handle), do: :ok
  end

  setup do
    c = service()
    observation = observation()
    profile = profile()
    {:ok, catalogue} = Catalogue.new([profile])
    service = %{c.service | catalogue: catalogue}
    {:ok, observation_identity} = Observation.identity(observation)

    Map.merge(c, %{
      service: service,
      observation: observation,
      profile: profile,
      observation_identity: observation_identity
    })
  end

  test "an authorized probe returns bounded private evidence without adapter authority", c do
    owner = start_probe(c, {Adapter, {self(), {:ok, <<0, 1, 255>>}}})

    assert {:ok, result} =
             ActiveProbe.probe(owner, c.service, c.admin, c.scope, request(c), c.now)

    assert_receive {:probe_adapter, _worker, adapter_request, 1_000}

    assert adapter_request == %{
             "schema" => "wtr.active-probe-adapter-request.v1",
             "transport" => "ble_gatt",
             "operation" => "read",
             "target" => target()
           }

    refute inspect(adapter_request) =~ c.admin
    refute inspect(adapter_request) =~ c.scope

    assert result == %{
             "schema" => "wtr.active-probe-result.v1",
             "request_id" => result["request_id"],
             "observation_identity" => c.observation_identity,
             "profile" => %{"id" => "synthetic.probe", "version" => "1.0.0"},
             "probe" => %{"id" => "device-information", "revision" => "1"},
             "transport" => "ble_gatt",
             "operation" => "read",
             "target" => Map.delete(target(), "object_path"),
             "target_identity" => result["target_identity"],
             "value" => %{"encoding" => "base64", "bytes" => 3, "data" => "AAH/"}
           }

    assert byte_size(result["target_identity"]) == 64
    refute inspect(result) =~ target()["object_path"]

    assert {:ok, resolution} =
             Resolution.resolve_with_probe(c.observation, c.service.catalogue, result)

    assert resolution.status == :resolved
    assert resolution.selected === c.profile
    assert resolution.confidence == :strong

    assert {:ok,
            %{
              "schema" => "wtr.active-probe-status.v1",
              "enabled" => true,
              "availability" => "available",
              "transports" => ["ble_gatt"],
              "probes" => 1,
              "active" => 0,
              "capacity" => 1
            }} = ActiveProbe.status(owner)
  end

  test "read authority alone and durable revocation deny a probe before transport", c do
    owner = start_probe(c, {Adapter, {self(), {:ok, <<1>>}}})

    assert {:error, :forbidden} =
             ActiveProbe.probe(owner, c.service, c.reader, c.scope, request(c), c.now)

    refute_receive {:probe_adapter, _, _, _}

    assert {:ok, %{"generation" => "1"}} =
             Service.revoke(
               c.service,
               c.admin,
               c.scope,
               Identifier.uuid(),
               %{"credential_id" => "admin", "expected_generation" => "0"},
               c.now + 1
             )

    assert {:error, :unauthorized} =
             ActiveProbe.probe(owner, c.service, c.admin, c.scope, request(c), c.now + 2)

    refute_receive {:probe_adapter, _, _, _}
  end

  test "caller loss, explicit cancellation and deadline terminate adapter work", c do
    owner = start_probe(c, {BlockingAdapter, self()})
    parent = self()

    caller =
      spawn(fn ->
        result = ActiveProbe.probe(owner, c.service, c.admin, c.scope, request(c), c.now)
        send(parent, {:caller_result, result})
      end)

    assert_receive {:blocking_probe, first_worker, _, 1_000}
    first_monitor = Process.monitor(first_worker)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^first_monitor, :process, ^first_worker, :killed}
    refute_receive {:caller_result, _}
    eventually_idle(owner)

    cancellation_request = request(c)

    cancellation =
      Task.async(fn ->
        ActiveProbe.probe(owner, c.service, c.admin, c.scope, cancellation_request, c.now)
      end)

    assert_receive {:blocking_probe, second_worker, _, 1_000}
    second_monitor = Process.monitor(second_worker)
    assert :ok = ActiveProbe.cancel(owner, cancellation_request["request_id"])
    assert Task.await(cancellation) == {:error, :cancelled}
    assert_receive {:DOWN, ^second_monitor, :process, ^second_worker, :killed}
    assert {:error, :not_found} = ActiveProbe.cancel(owner, cancellation_request["request_id"])

    deadline_owner =
      start_probe(c, {BlockingAdapter, self()}, config(%{"timeout_ms" => 100}))

    deadline_request = request(c)

    task =
      Task.async(fn ->
        ActiveProbe.probe(deadline_owner, c.service, c.admin, c.scope, deadline_request, c.now)
      end)

    assert_receive {:blocking_probe, deadline_worker, _, 100}
    deadline_monitor = Process.monitor(deadline_worker)
    assert Task.await(task, 1_000) == {:error, :deadline_exceeded}
    assert_receive {:DOWN, ^deadline_monitor, :process, ^deadline_worker, :killed}
  end

  test "an unexpected worker death is contained and unavailable APIs stay closed", c do
    owner = start_probe(c, {BlockingAdapter, self()})

    task =
      Task.async(fn ->
        ActiveProbe.probe(owner, c.service, c.admin, c.scope, request(c), c.now)
      end)

    assert_receive {:blocking_probe, worker, _, _}
    Process.exit(worker, :kill)
    assert Task.await(task) == {:error, :unavailable}
    assert Process.alive?(owner)

    send(owner, :unrelated_message)
    assert {:ok, %{"active" => 0}} = ActiveProbe.status(owner)
    assert inspect(:sys.get_status(owner)) =~ "redacted"

    dead = spawn(fn -> :ok end)
    monitor = Process.monitor(dead)
    assert_receive {:DOWN, ^monitor, :process, ^dead, :normal}
    assert {:error, :unavailable} = ActiveProbe.status(dead)
    assert {:error, :unavailable} = ActiveProbe.cancel(dead, Identifier.uuid())

    assert {:error, :unavailable} =
             ActiveProbe.probe(dead, c.service, c.admin, c.scope, request(c), c.now)
  end

  test "finite concurrency and request identity prevent overlapping ambiguity", c do
    owner = start_probe(c, {BlockingAdapter, self()})
    first_request = request(c)

    first =
      Task.async(fn ->
        ActiveProbe.probe(owner, c.service, c.admin, c.scope, first_request, c.now)
      end)

    assert_receive {:blocking_probe, worker, _, _}

    duplicate =
      Task.async(fn ->
        ActiveProbe.probe(owner, c.service, c.admin, c.scope, first_request, c.now)
      end)

    assert Task.await(duplicate) == {:error, :conflict}

    overloaded_request = request(c, %{"request_id" => Identifier.uuid()})

    assert {:error, :overloaded} =
             ActiveProbe.probe(owner, c.service, c.admin, c.scope, overloaded_request, c.now)

    send(worker, {:release, {:ok, <<42>>}})
    assert {:ok, %{"value" => %{"data" => "Kg=="}}} = Task.await(first)
  end

  test "oversized, malformed, rejected and failing adapter results remain closed", c do
    oversized =
      start_probe(
        c,
        {Adapter, {self(), {:ok, <<1, 2, 3>>}}},
        config(%{"max_value_bytes" => 2})
      )

    assert {:error, :response_too_large} =
             ActiveProbe.probe(
               oversized,
               c.service,
               c.admin,
               c.scope,
               request(c),
               c.now
             )

    assert_receive {:probe_adapter, _, _, _}

    for {adapter_result, expected} <- [
          {{:error, :rejected}, {:error, :probe_rejected}},
          {{:error, :private}, {:error, :unavailable}},
          {{:ok, :not_bytes}, {:error, :unavailable}},
          {:raise, {:error, :unavailable}},
          {{:throw, :private}, {:error, :unavailable}}
        ] do
      owner = start_probe(c, {Adapter, {self(), adapter_result}})
      assert ActiveProbe.probe(owner, c.service, c.admin, c.scope, request(c), c.now) == expected
      assert_receive {:probe_adapter, _, _, _}
      assert Process.alive?(owner)
    end
  end

  test "disabled, absent and invalid configurations start no hidden transport work", c do
    assert :ignore =
             ActiveProbe.start_link(
               config: %{"schema" => "wtr.active-probe-host.v1", "enabled" => false}
             )

    unavailable = start_probe(c, nil)

    assert {:ok, %{"availability" => "unavailable"}} = ActiveProbe.status(unavailable)

    assert {:error, :unavailable} =
             ActiveProbe.probe(unavailable, c.service, c.admin, c.scope, request(c), c.now)

    for config <- [
          %{"schema" => "wtr.active-probe-host.v1", "enabled" => false, "extra" => true},
          config(%{"transport" => "ble_scan"}),
          config(%{"operation" => "write"}),
          config(%{"timeout_ms" => 99}),
          config(%{"timeout_ms" => 1_001}),
          config(%{"timeout_ms" => 30_001}),
          config(%{"max_value_bytes" => 0}),
          config(%{"max_value_bytes" => 33}),
          config(%{"max_value_bytes" => 513}),
          Map.put(config(), "max_concurrency", 0),
          Map.put(config(), "probes", []),
          Map.put(config(), "probes", List.duplicate(plan(), 2)),
          config(%{"profile" => %{"id" => "profile"}}),
          config(%{"profile" => %{"id" => "other", "version" => "1"}}),
          config(%{
            "profile" => %{"id" => "synthetic.probe", "version" => 1}
          }),
          config(%{"probe" => %{"id" => "probe"}}),
          config(%{"target" => nil}),
          config(%{"target" => target() |> Map.delete("generation") |> Map.put("extra", 9)}),
          config(%{"target" => Map.put(target(), "service_uuid", 0x180A)}),
          config(%{"target" => Map.put(target(), "service_uuid", "180F")}),
          config(%{"target" => Map.put(target(), "service_uuid", "180f")}),
          config(%{"target" => Map.put(target(), "characteristic_uuid", "bad")}),
          config(%{"target" => Map.put(target(), "handle", 0)}),
          config(%{"target" => Map.put(target(), "object_path", "relative")}),
          config(%{"target" => Map.put(target(), "generation", 9_007_199_254_740_992)}),
          config(%{"extra" => true}),
          Map.put(config(), "extra", true)
        ] do
      assert {:error, :invalid_options} =
               ActiveProbe.start_link(config: config, catalogue: c.service.catalogue)
    end

    assert {:error, :invalid_options} = ActiveProbe.start_link([])
    assert {:error, :invalid_options} = ActiveProbe.start_link(config: config())

    assert {:error, :invalid_options} =
             ActiveProbe.start_link(
               config: config(),
               catalogue: c.service.catalogue,
               unknown: true
             )

    assert {:error, :invalid_options} =
             ActiveProbe.start_link(
               config: config(),
               catalogue: c.service.catalogue,
               adapter: :bad
             )

    nullable_target = %{
      "service_uuid" => "0000180a-0000-1000-8000-00805f9b34fb",
      "characteristic_uuid" => "00002a29-0000-1000-8000-00805f9b34fb",
      "handle" => nil,
      "object_path" => nil,
      "generation" => nil
    }

    nullable_owner =
      start_probe(c, {Adapter, {self(), {:ok, <<1>>}}}, config(%{"target" => nullable_target}))

    public_nullable_target = Map.delete(nullable_target, "object_path")

    assert {:ok, %{"target" => ^public_nullable_target}} =
             ActiveProbe.probe(nullable_owner, c.service, c.admin, c.scope, request(c), c.now)
  end

  test "the request contract rejects widened, noncanonical and unconfigured plans", c do
    owner = start_probe(c, {Adapter, {self(), {:ok, <<1>>}}})

    invalid = [
      Map.put(request(c), "extra", true),
      Map.put(request(c), "schema", "wtr.active-probe-request.v2"),
      Map.put(request(c), "request_id", "request"),
      Map.put(request(c), "observation_identity", String.duplicate("a", 64)),
      put_in(request(c), ["profile", "version"], "bad\nrevision"),
      put_in(request(c), ["profile", "version"], 1),
      put_in(request(c), ["probe"], %{"id" => "probe"}),
      put_in(request(c), ["profile", "id"], "unconfigured"),
      put_in(request(c), ["probe", "id"], "unconfigured")
    ]

    for value <- invalid do
      assert {:error, :invalid_request} =
               ActiveProbe.probe(owner, c.service, c.admin, c.scope, value, c.now)
    end

    refute_receive {:probe_adapter, _, _, _}
  end

  test "the concrete adapter executes one upstream byte read on the host-owned session", c do
    {:ok, session} =
      BLE.connect(
        client: BLEClient,
        owner: self(),
        result: {:ok, <<52, 18>>},
        timeout: 5_000
      )

    owner = start_probe(c, {BLEProbeAdapter, session})

    assert {:ok, %{"value" => %{"bytes" => 2, "data" => "NBI="}}} =
             ActiveProbe.probe(owner, c.service, c.admin, c.scope, request(c), c.now)

    assert_receive {:ble_read, message, 1_000}

    assert message == %{
             type: :read,
             service: "0000180a-0000-1000-8000-00805f9b34fb",
             characteristic: "00002a29-0000-1000-8000-00805f9b34fb",
             handle: 37,
             object_path: target()["object_path"],
             generation: 9
           }

    refute inspect(session) =~ "private-peer-handle"
  end

  test "the concrete adapter hides upstream failures and preserves permission denial", c do
    for {upstream, expected} <- [
          {{:error, BLEError.new(:not_authorized)}, {:error, :probe_rejected}},
          {{:error, BLEError.new(:timeout, nil, %{private: "detail"})}, {:error, :unavailable}},
          {:invalid, {:error, :unavailable}}
        ] do
      {:ok, session} =
        BLE.connect(
          client: BLEClient,
          owner: self(),
          result: upstream,
          timeout: 5_000
        )

      owner = start_probe(c, {BLEProbeAdapter, session})
      result = ActiveProbe.probe(owner, c.service, c.admin, c.scope, request(c), c.now)
      assert result == expected
      refute inspect(result) =~ "detail"
      assert_receive {:ble_read, _, 1_000}
    end

    assert {:error, :unavailable} = BLEProbeAdapter.read(:forged, %{}, 1_000)
  end

  defp start_probe(c, adapter, probe_config \\ config()) do
    start_supervised!(
      Supervisor.child_spec(
        {ActiveProbe, config: probe_config, catalogue: c.service.catalogue, adapter: adapter},
        id: {ActiveProbe, make_ref()},
        restart: :temporary
      )
    )
  end

  defp config(plan_changes \\ %{}) do
    %{
      "schema" => "wtr.active-probe-host.v1",
      "enabled" => true,
      "probes" => [Map.merge(plan(), plan_changes)],
      "max_concurrency" => 1
    }
  end

  defp plan do
    %{
      "profile" => %{"id" => "synthetic.probe", "version" => "1.0.0"},
      "probe" => %{"id" => "device-information", "revision" => "1"},
      "transport" => "ble_gatt",
      "operation" => "read",
      "target" => target(),
      "timeout_ms" => 1_000,
      "max_value_bytes" => 32
    }
  end

  defp request(c, changes \\ %{}) do
    Map.merge(
      %{
        "schema" => "wtr.active-probe-request.v1",
        "request_id" => Identifier.uuid(),
        "observation_identity" => c.observation_identity,
        "profile" => %{"id" => "synthetic.probe", "version" => "1.0.0"},
        "probe" => %{"id" => "device-information", "revision" => "1"}
      },
      changes
    )
  end

  defp target do
    %{
      "service_uuid" => "180a",
      "characteristic_uuid" => "2a29",
      "handle" => 37,
      "object_path" => "/org/bluez/hci0/dev_fixture/service0001/char0002",
      "generation" => 9
    }
  end

  defp profile do
    {:ok, profile} =
      DeviceProfile.new(%{
        id: "synthetic.probe",
        version: "1.0.0",
        confidence: :candidate,
        fingerprints: [%{"op" => "byte", "offset" => 0, "value" => 5}],
        probes: [
          %{
            "id" => "device-information",
            "revision" => "1",
            "transport" => "ble_gatt",
            "operation" => "read",
            "target" => %{
              "service_uuid" => "180a",
              "characteristic_uuid" => "2a29"
            },
            "timeout_ms" => 1_000,
            "max_value_bytes" => 32,
            "predicates" => [
              %{"op" => "length", "value" => 3},
              %{
                "op" => "bytes",
                "offset" => 0,
                "encoding" => "base64",
                "data" => "AAH/"
              }
            ],
            "match_confidence" => "strong",
            "mismatch" => "reject",
            "failure" => "unavailable"
          }
        ],
        decoder: {"synthetic", "1"},
        model: {"urn:wotex:tm:tracker:environmental-sensor", "1.0.0"},
        mapping_revision: "1",
        mapping: %{},
        source_provenance: %{"kind" => "synthetic"}
      })

    profile
  end

  defp eventually_idle(owner, attempts \\ 100)

  defp eventually_idle(_owner, 0), do: flunk("probe owner did not become idle")

  defp eventually_idle(owner, attempts) do
    case ActiveProbe.status(owner) do
      {:ok, %{"active" => 0}} -> :ok
      _ -> eventually_idle(owner, attempts - 1)
    end
  end
end
