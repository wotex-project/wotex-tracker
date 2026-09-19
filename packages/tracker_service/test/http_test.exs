defmodule Wotex.Tracker.HTTPTest do
  @moduledoc false
  use ExUnit.Case, async: true
  import Wotex.Tracker.Service.Fixtures
  alias Wotex.Tracker.Decoders.RuuviRawV2
  alias Wotex.Tracker.{Evidence, EvidenceBundle, Observation, PolicyFact}
  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.{Codec, Identifier, RuleFixtures, Store}
  alias Wotex.Tracker.Service.HTTP.{Capacity, Server}

  test "an independent HTTP/SSE process executes the authenticated workflow" do
    context = service()
    server = start_supervised!({Server, options(context)})
    assert run_consumer(context, server, %{}) =~ "HTTP_CONSUMER_PASS"
    assert {:ok, capacity} = Server.child(server, :capacity)
    assert_capacity_released(capacity)
  end

  test "an independent HTTP process inspects persisted rule status" do
    context = service()
    RuleFixtures.commit_all(context.store, context.scope)
    server = start_supervised!({Server, options(context)})
    output = run_consumer(context, server, %{"mode" => "rules"})
    assert output =~ "HTTP_CONSUMER_PASS openapi=true rule_status=true alerts=true"
    assert {:ok, capacity} = Server.child(server, :capacity)
    assert_capacity_released(capacity)
  end

  test "an independent HTTP process validates a completed trip summary", do: trip_summary_peer()

  test "an independent HTTP process triggers a suspicious-movement alert",
    do: suspicious_orchestration_peer()

  test "an independent HTTP process commits and reads arming state" do
    context = service()
    {thing, _td} = materialized(context)
    server = start_supervised!({Server, options(context)})

    output = run_consumer(context, server, %{"mode" => "arming", "thing" => thing})
    assert output =~ "HTTP_CONSUMER_PASS openapi=true arming=true private_fact=false"
    assert {:ok, capacity} = Server.child(server, :capacity)
    assert_capacity_released(capacity)
  end

  test "an independent HTTP process admits and reads owner-presence evidence" do
    context = service()
    {thing, _td} = materialized(context)
    server = start_supervised!({Server, options(context)})

    output =
      run_consumer(context, server, %{
        "mode" => "owner_presence",
        "thing" => thing,
        "fact" => owner_presence_fact(thing, context.now)
      })

    assert output =~
             "HTTP_CONSUMER_PASS openapi=true owner_presence=true private_fact=false"

    assert {:ok, capacity} = Server.child(server, :capacity)
    assert_capacity_released(capacity)
  end

  test "an independent HTTP process registers, rotates and removes a private push endpoint" do
    context = service()
    server = start_supervised!({Server, options(context)})

    output = run_consumer(context, server, %{"mode" => "notification_endpoints"})

    assert output =~
             "HTTP_CONSUMER_PASS openapi=true notification_endpoints=true private_token=false"

    assert {:ok, capacity} = Server.child(server, :capacity)
    assert_capacity_released(capacity)
  end

  test "instances use distinct listeners and stores; invalid exposure and configuration fail closed" do
    first = service()
    second = service()
    a = start_supervised!(Supervisor.child_spec({Server, options(first)}, id: :a))
    b = start_supervised!(Supervisor.child_spec({Server, options(second)}, id: :b))
    assert {:ok, {_, port_a}} = Server.listener_info(a)
    assert {:ok, {_, port_b}} = Server.listener_info(b)
    refute port_a == port_b
    assert {:ok, store_a} = Server.child(a, :store)
    assert {:ok, store_b} = Server.child(b, :store)
    refute store_a == store_b
    assert {:ok, %{"writable" => true}} = Store.readiness(Store.handle(store_a))
    assert {:ok, %{"writable" => true}} = Store.readiness(Store.handle(store_b))

    for change <- [
          [ip: {0, 0, 0, 0}],
          [port: -1],
          [public_origin: "http://user:pass@example.test"],
          [exposure: :proxy, public_origin: "http://example.test"],
          [exposure: :tls],
          [request_timeout: 5001],
          [stream_lifetime: 300_001],
          [poll_interval: 0],
          [store_options: [fault: fn _ -> :ok end]],
          [unknown: true]
        ] do
      assert {:error, :invalid_configuration} =
               Server.start_link(Keyword.merge(options(first), change))
    end

    assert {:error, :invalid_configuration} = Server.start_link([])
    assert {:error, :invalid_configuration} = Server.start_link(nil)
  end

  defp run_consumer(context, server, descriptor) do
    assert {:ok, {{127, 0, 0, 1}, port}} = Server.listener_info(server)
    path = Path.join(context.directory, "client.json")

    File.write!(
      path,
      Codec.encode!(
        Map.merge(descriptor, %{
          "url" => "http://127.0.0.1:#{port}",
          "token" => context.admin,
          "reader" => context.reader,
          "scope" => context.scope,
          "now" => context.now
        })
      )
    )

    File.chmod!(path, 0o600)
    elixir = System.find_executable("elixir") || flunk("Elixir executable is unavailable")
    code_paths = Enum.flat_map(:code.get_path(), fn value -> ["-pa", List.to_string(value)] end)
    script = Path.expand("../../scripts/http_consumer.exs")
    {output, status} = System.cmd(elixir, code_paths ++ [script, path], stderr_to_stdout: true)
    File.rm!(path)
    assert status == 0, output
    output
  end

  defp owner_presence_fact(thing, now) do
    {:ok, observation} =
      Observation.new(%{
        id: "presence-observation-http",
        observed_at: now,
        ingress: "imported",
        source: %{"kind" => "qualified-owner-presence"},
        addressing: %{"thing_id" => thing},
        payload: {:json, %{"predicate" => "owner.present", "status" => "false"}},
        radio: %{},
        transport: %{},
        provenance: %{"kind" => "http-consumer-fixture"}
      })

    {:ok, evidence} =
      Evidence.new(%{
        id: "presence-evidence-http",
        kind: :identity,
        claim: %{
          "schema" => "wtr.policy-fact.v1",
          "predicate" => "owner.present",
          "status" => "false",
          "policy_revision" => "presence-source-v1",
          "reason" => "qualified_observation"
        },
        source_observation_ids: [observation.id],
        evidence_ids: [],
        profile: {"test-presence", "1"},
        decoder: {"test-presence", "1"},
        confidence: :exact,
        reasons: ["qualified_observation"],
        association_id: thing
      })

    {:ok, bundle} = EvidenceBundle.new([observation], [evidence])
    {:ok, fact} = PolicyFact.new(evidence.id, bundle)
    {:ok, document} = PolicyFact.to_map(fact)
    document
  end

  defp assert_capacity_released(capacity, attempts \\ 100) do
    case Capacity.counts(capacity) do
      %{requests: 0, streams: 0} ->
        :ok

      counts ->
        assert attempts > 0, "HTTP peer closure retained capacity: #{inspect(counts)}"
        Process.sleep(10)
        assert_capacity_released(capacity, attempts - 1)
    end
  end

  defp options(context),
    do: [
      directory: context.directory,
      credentials: context.credentials,
      ip: {127, 0, 0, 1},
      port: 0,
      public_origin: :listener,
      exposure: :loopback,
      clock: fn -> context.now end,
      poll_interval: 25
    ]

  defp trip_summary_peer do
    context = position_service()
    {thing, _td} = materialized(context)

    assert {:ok, %{"generation" => "4"}} =
             Service.save_policy(
               context.service,
               context.admin,
               context.scope,
               Identifier.uuid(),
               motion(thing, "3"),
               context.now
             )

    assert {:ok, %{"generation" => "7"}} =
             materialize_position(context, thing, "moving-one", context.now + 1_000, "4")

    assert {:ok, %{"generation" => "10"}} =
             materialize_position(context, thing, "moving-two", context.now + 2_000, "7")

    assert {:ok, %{"value" => %{"motion" => %{"active_trip" => %{"id" => trip}}}}} =
             Service.get(
               context.service,
               context.reader,
               context.scope,
               "rules",
               "motion:movement",
               context.now + 2_000
             )

    assert {:ok, %{"generation" => "13"}} =
             materialize_position(context, thing, "stopped-one", context.now + 3_000, "10")

    assert {:ok, %{"generation" => "16"}} =
             materialize_position(context, thing, "stopped-two", context.now + 4_000, "13")

    server = start_supervised!({Server, options(context)})

    output =
      run_consumer(context, server, %{
        "mode" => "trip_summary",
        "thing" => thing,
        "trip" => trip
      })

    assert output =~ "HTTP_CONSUMER_PASS openapi=true trip_summary=true private_ids=false"
    assert {:ok, capacity} = Server.child(server, :capacity)
    assert_capacity_released(capacity)
  end

  defp suspicious_orchestration_peer do
    context = position_service()
    {thing, _td} = materialized(context)

    assert {:ok, %{"generation" => "4"}} =
             Service.save_policy(
               context.service,
               context.admin,
               context.scope,
               Identifier.uuid(),
               motion(thing, "3"),
               context.now
             )

    assert {:ok, %{"generation" => "5"}} =
             Service.save_policy(
               context.service,
               context.admin,
               context.scope,
               Identifier.uuid(),
               suspicious(thing, "4"),
               context.now
             )

    assert {:ok, %{"generation" => "8"}} =
             materialize_position(context, thing, "moving-one", context.now + 1_000, "5")

    assert {:ok, %{"generation" => "11"}} =
             materialize_position(context, thing, "moving-two", context.now + 2_000, "8")

    assert {:ok, %{"generation" => "12"}} =
             Service.set_arming(
               context.service,
               context.admin,
               context.scope,
               Identifier.uuid(),
               %{"thing_id" => thing, "status" => "armed", "expected_generation" => "11"},
               context.now
             )

    server = start_supervised!({Server, options(context)})

    output =
      run_consumer(context, server, %{
        "mode" => "suspicious_orchestration",
        "thing" => thing,
        "fact" => owner_presence_fact(thing, context.now)
      })

    assert output =~
             "HTTP_CONSUMER_PASS openapi=true suspicious_orchestration=true private_ids=false"

    assert {:ok, capacity} = Server.child(server, :capacity)
    assert_capacity_released(capacity)
  end

  defp position_service do
    context = service()
    {:ok, profile} = RuuviRawV2.profile()
    revision = {"fixture.http-trip-summary", "1.0.0"}
    profile = %{profile | id: elem(revision, 0), version: elem(revision, 1), decoder: revision}
    {:ok, catalogue} = Wotex.Tracker.catalogue([profile])

    callback = fn observation ->
      {:ok, decoded} = RuuviRawV2.decode(observation)
      {:ok, %{decoded | positions: [position_claim(observation)]}}
    end

    {:ok, configured} =
      Service.new(%{
        store: context.store,
        credentials: context.credentials,
        base_url: context.service.base_url,
        catalogue: catalogue,
        model: context.service.model,
        decoders: [{revision, callback}]
      })

    Map.put(context, :service, configured)
  end

  defp materialize_position(context, thing, id, observed_at, generation) do
    {:ok, imported} =
      Service.submit(
        context.service,
        context.admin,
        context.scope,
        Identifier.uuid(),
        import_request(%{id: id, observed_at: observed_at}, generation),
        observed_at
      )

    associated_generation = Integer.to_string(String.to_integer(generation) + 1)

    {:ok, _} =
      Service.associate(
        context.service,
        context.admin,
        context.scope,
        Identifier.uuid(),
        %{
          "thing_id" => thing,
          "observation_id" => imported["data"]["observation_id"],
          "owner_confirmed" => true,
          "expected_generation" => associated_generation
        },
        observed_at
      )

    Service.materialize(
      context.service,
      context.admin,
      context.scope,
      Identifier.uuid(),
      %{
        "thing_id" => thing,
        "expected_generation" => Integer.to_string(String.to_integer(associated_generation) + 1)
      },
      observed_at
    )
  end

  defp motion(thing, generation),
    do: %{
      "id" => "movement",
      "kind" => "motion",
      "thing_id" => thing,
      "parameters" => %{
        "event_time" => "trusted_fix",
        "future_skew_ms" => 0,
        "late_window_ms" => 10_000,
        "sequence" => "none",
        "moving_speed_m_s" => 1.0,
        "stationary_speed_m_s" => 0.1,
        "moving_distance_m" => 1.0,
        "stationary_distance_m" => 0.5,
        "max_plausible_speed_m_s" => 1_000.0,
        "max_gap_ms" => 10_000,
        "uncertainty" => "coordinate_only",
        "minimum_movement_ms" => 1_000,
        "minimum_stop_ms" => 1_000
      },
      "expected_generation" => generation
    }

  defp suspicious(thing, generation),
    do: %{
      "id" => "suspicious-motion",
      "kind" => "suspicious_movement",
      "thing_id" => thing,
      "parameters" => %{
        "motion_rule_id" => "movement",
        "maximum_fact_age_ms" => 60_000,
        "future_skew_ms" => 1_000,
        "owner_unknown_as_absent" => false
      },
      "expected_generation" => generation
    }

  defp position_claim(observation) do
    longitude =
      if observation.id in ~w(moving-one),
        do: 18.0686,
        else: 18.0646

    %{
      "schema" => "wtr.position.v1",
      "latitude" => 59.3293,
      "longitude" => longitude,
      "altitude_m" => nil,
      "speed_m_s" => nil,
      "horizontal_accuracy_m" => 5.0,
      "accuracy_kind" => "bound",
      "source" => "gnss",
      "fix_at" => observation.observed_at,
      "device_at" => nil,
      "received_at" => observation.observed_at,
      "fix_clock" => "trusted",
      "device_clock" => "unknown",
      "availability" => "available",
      "quality" => "valid",
      "source_units" => %{
        "latitude" => "degree",
        "longitude" => "degree",
        "altitude" => nil,
        "speed" => nil,
        "accuracy" => "m",
        "fix_time" => "unix-ms",
        "device_time" => nil,
        "receiver_time" => "unix-ms"
      },
      "conversion_revision" => "fixture-http-trip-summary-v1",
      "raw" => %{},
      "receiver_observation_id" => observation.id
    }
  end
end
