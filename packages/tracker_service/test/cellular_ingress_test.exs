defmodule Wotex.Tracker.Service.CellularIngressTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import Wotex.Tracker.Service.Fixtures

  alias Wotex.Tracker.Observation
  alias Wotex.Tracker.Protocols.Teltonika.{Codec8Extended, TAT140, TCPSession}
  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.Cellular.Ingress
  alias Wotex.Tracker.Service.{Codec, Identifier}

  @imei "123456789012345"
  @identity_key :binary.copy(<<7>>, 32)

  setup do
    context = service()
    %{context: context, packet: packet(), ingress: start_ingress(context)}
  end

  test "configured IMEI admits without retention and unknown identifiers fail", context do
    assert {:error, :unauthorized} = Ingress.login(context.ingress, "123456789012346")
    assert {:error, :invalid_request} = Ingress.login(context.ingress, "not-an-imei")
    assert {:ok, session} = Ingress.login(context.ingress, @imei)
    assert inspect(session) == "#Wotex.Tracker.Service.Cellular.Ingress.Session<...>"
    refute :sys.get_status(context.ingress) |> inspect() =~ @imei

    assert :ok = Ingress.close(context.ingress, session)
    assert :ok = Ingress.close(context.ingress, :forged)
    _ = :sys.get_state(context.ingress)
    assert {:error, :unauthorized} = Ingress.submit(context.ingress, session, context.packet)
  end

  test "a corrupted configured digest cannot authorize an existing session", context do
    assert {:ok, session} = Ingress.login(context.ingress, @imei)

    :sys.replace_state(context.ingress, fn state ->
      [device] = state.devices
      %{state | devices: [%{device | identity_digest: "short"}]}
    end)

    assert {:error, :unauthorized} = Ingress.submit(context.ingress, session, context.packet)
  end

  test "accepted packet commits once and exact retransmissions reconcile as duplicates",
       context do
    assert {:ok, first_session} = Ingress.login(context.ingress, @imei)

    assert {:ok, %{disposition: :accepted, record_count: 1} = first} =
             Ingress.submit(context.ingress, first_session, context.packet)

    assert {:ok, {:send, <<0, 0, 0, 1>>}} =
             TCPSession.data_reply(first.record_count, first.disposition)

    assert {:ok, %{disposition: :duplicate, operation_id: operation}} =
             Ingress.submit(context.ingress, first_session, context.packet)

    assert operation == first.operation_id

    assert {:ok, second_session} = Ingress.login(context.ingress, @imei)

    assert {:ok, %{disposition: :duplicate, operation_id: ^operation}} =
             Ingress.submit(context.ingress, second_session, context.packet)

    assert {:ok, %{"generation" => "1", "items" => [%{"id" => id}]}} =
             Service.list(
               context.context.service,
               context.context.admin,
               context.context.scope,
               "observations",
               %{"limit" => 10},
               context.context.now
             )

    assert {:ok, raw} =
             Service.raw_observation(
               context.context.service,
               context.context.admin,
               context.context.scope,
               id,
               context.context.now
             )

    document = Codec.decode!(raw)
    assert document["provenance"]["configured_profile"] == TAT140.configured_profile()
    assert {:ok, observation} = Observation.from_map(document)
    assert {:ok, %{kind: :avl_data, record_count: 1}} = TAT140.decode(observation)
  end

  test "concurrent sessions serialize one frame into one durable operation", context do
    sessions =
      for _ <- 1..8 do
        {:ok, session} = Ingress.login(context.ingress, @imei)
        session
      end

    results =
      sessions
      |> Task.async_stream(&Ingress.submit(context.ingress, &1, context.packet),
        ordered: false,
        max_concurrency: 8
      )
      |> Enum.map(fn {:ok, {:ok, receipt}} -> receipt end)

    assert Enum.count(results, &(&1.disposition == :accepted)) == 1
    assert Enum.count(results, &(&1.disposition == :duplicate)) == 7
    assert results |> Enum.map(& &1.operation_id) |> Enum.uniq() |> length() == 1
  end

  test "unknown post-commit result closes, then retained receipt reconciles duplicate" do
    context = service(fault: fn phase -> if phase == :after_commit, do: :abort, else: :ok end)
    ingress = start_ingress(context)
    assert {:ok, session} = Ingress.login(ingress, @imei)

    assert {:ok, %{disposition: :unknown, record_count: 1}} =
             Ingress.submit(ingress, session, packet())

    assert {:ok, :close} = TCPSession.data_reply(1, :unknown)

    assert {:ok, %{disposition: :duplicate, record_count: 1}} =
             Ingress.submit(ingress, session, packet())
  end

  test "loss of the store after receipt lookup remains an unknown outcome", context do
    store = context.context.store

    pid = spawn(&fail_after_operation/0)

    failed_store = %{store | pid: pid}
    failed_service = %{context.context.service | store: failed_store}
    failed_context = %{context.context | service: failed_service, store: failed_store}
    ingress = start_ingress(failed_context)
    assert {:ok, session} = Ingress.login(ingress, @imei)

    assert {:ok, %{disposition: :unknown}} = Ingress.submit(ingress, session, context.packet)
  end

  test "known pre-commit failure rejects with zero ACK and forged packets fail" do
    context = service(fault: fn phase -> if phase == :before_commit, do: :abort, else: :ok end)
    ingress = start_ingress(context)
    assert {:ok, session} = Ingress.login(ingress, @imei)

    assert {:ok, %{disposition: :rejected, record_count: 1}} =
             Ingress.submit(ingress, session, packet())

    assert {:ok, {:send, <<0, 0, 0, 0>>}} = TCPSession.data_reply(1, :rejected)

    assert {:error, :invalid_request} =
             Ingress.submit(ingress, session, %{packet() | record_count: 2})

    assert {:error, :invalid_request} = Ingress.submit(ingress, session, %{})
    assert {:error, :invalid_request} = Ingress.submit(ingress, :forged, packet())
  end

  test "configuration and live session capacity are finite", context do
    assert {:error, :invalid_configuration} = Ingress.start_link([])
    assert {:error, :invalid_configuration} = Ingress.start_link(:invalid)

    options = ingress_options(context.context) ++ [maximum_sessions: 1]
    ingress = start_supervised!({Ingress, options})
    assert {:ok, _} = Ingress.login(ingress, @imei)
    assert {:error, :busy} = Ingress.login(ingress, @imei)
  end

  test "a trusted provider resolves the current service for each admission", context do
    options =
      Keyword.put(ingress_options(context.context), :service, fn ->
        {:ok, context.context.service}
      end)

    ingress = start_supervised!(Supervisor.child_spec({Ingress, options}, id: make_ref()))
    assert {:ok, session} = Ingress.login(ingress, @imei)
    assert {:ok, %{disposition: :accepted}} = Ingress.submit(ingress, session, context.packet)

    for provider <- [
          fn -> {:error, :unavailable} end,
          fn -> {:ok, :forged} end,
          fn -> raise "provider failure" end,
          fn -> throw(:provider_failure) end
        ] do
      failed =
        ingress_options(context.context)
        |> Keyword.put(:service, provider)
        |> then(&start_supervised!(Supervisor.child_spec({Ingress, &1}, id: make_ref())))

      assert {:ok, failed_session} = Ingress.login(failed, @imei)

      assert {:ok, %{disposition: :rejected}} =
               Ingress.submit(failed, failed_session, context.packet)
    end
  end

  test "configuration rejects malformed limits, keys and device entries", context do
    valid = ingress_options(context.context)
    [device] = valid[:devices]

    invalid = [
      Keyword.put(valid, :identity_key, :binary.copy(<<0>>, 31)),
      Keyword.put(valid, :devices, []),
      Keyword.put(valid, :devices, :invalid),
      Keyword.put(valid, :devices, [%{invalid: true}]),
      Keyword.put(valid, :devices, [%{device | identity_digest: "short"}]),
      Keyword.put(valid, :devices, [%{device | token: "invalid"}]),
      Keyword.put(valid, :devices, [%{device | scope: ""}]),
      Keyword.put(valid, :devices, [%{device | id: ""}]),
      Keyword.put(valid, :devices, [%{device | profile: ""}]),
      Keyword.put(valid, :devices, [Map.put(device, :unknown, true)]),
      Keyword.put(valid, :devices, [device, %{device | id: "other"}]),
      Keyword.put(valid, :devices, [
        device,
        %{device | identity_digest: String.duplicate("0", 64)}
      ]),
      Keyword.put(valid, :maximum_sessions, 0),
      Keyword.put(valid, :maximum_retries, 4),
      valid ++ [unknown: true],
      valid ++ [service: context.context.service]
    ]

    for options <- invalid do
      assert {:error, :invalid_configuration} = Ingress.start_link(options)
    end

    assert {:ok, default_clock} = Ingress.start_link(Keyword.delete(valid, :clock))
    assert {:ok, session} = Ingress.login(default_clock, @imei)

    assert {:ok, %{disposition: :rejected}} =
             Ingress.submit(default_clock, session, context.packet)

    assert :ok = GenServer.stop(default_clock)

    without_profile =
      Keyword.put(valid, :devices, [Map.delete(device, :profile)])

    assert {:ok, generic} = Ingress.start_link(without_profile)
    assert {:ok, generic_session} = Ingress.login(generic, @imei)

    assert {:ok, %{disposition: :accepted}} =
             Ingress.submit(generic, generic_session, context.packet)

    assert {:ok, %{"items" => [%{"id" => id}]}} =
             Service.list(
               context.context.service,
               context.context.admin,
               context.context.scope,
               "observations",
               %{"limit" => 10},
               context.context.now
             )

    assert {:ok, raw} =
             Service.raw_observation(
               context.context.service,
               context.context.admin,
               context.context.scope,
               id,
               context.context.now
             )

    assert is_nil(Codec.decode!(raw)["provenance"]["configured_profile"])
    assert :ok = GenServer.stop(generic)
  end

  test "an invalid trusted clock rejects without touching durable state", context do
    for clock <- [
          fn -> :invalid end,
          fn -> raise "private clock failure" end,
          fn -> throw(:private_clock_failure) end
        ] do
      ingress =
        start_supervised!(
          Supervisor.child_spec(
            {Ingress, Keyword.put(ingress_options(context.context), :clock, clock)},
            id: make_ref(),
            restart: :temporary
          )
        )

      assert {:ok, session} = Ingress.login(ingress, @imei)

      assert {:ok, %{disposition: :rejected}} =
               Ingress.submit(ingress, session, context.packet)
    end
  end

  test "a content duplicate committed under another operation still receives a full ACK",
       context do
    document = cellular_document(context.context, context.packet)

    assert {:ok, %{"disposition" => "accepted"}} =
             Service.submit(
               context.context.service,
               context.context.admin,
               context.context.scope,
               Identifier.uuid(),
               %{"observation" => document, "expected_generation" => "0"},
               context.context.now
             )

    assert {:ok, session} = Ingress.login(context.ingress, @imei)

    assert {:ok, %{disposition: :duplicate, record_count: 1}} =
             Ingress.submit(context.ingress, session, context.packet)
  end

  test "an expired retained operation closes for reconciliation instead of guessing", context do
    assert {:ok, session} = Ingress.login(context.ingress, @imei)

    assert {:ok, %{disposition: :accepted}} =
             Ingress.submit(context.ingress, session, context.packet)

    later = context.context.now + 8 * 24 * 60 * 60 * 1000

    ingress =
      start_supervised!(
        Supervisor.child_spec(
          {Ingress, Keyword.put(ingress_options(context.context), :clock, fn -> later end)},
          id: make_ref(),
          restart: :temporary
        )
      )

    assert {:ok, later_session} = Ingress.login(ingress, @imei)

    assert {:ok, %{disposition: :unknown}} =
             Ingress.submit(ingress, later_session, context.packet)
  end

  defp start_ingress(context) do
    start_supervised!(
      Supervisor.child_spec({Ingress, ingress_options(context)},
        id: make_ref(),
        restart: :temporary
      )
    )
  end

  defp ingress_options(context) do
    {:ok, identity_digest} = TCPSession.identity_digest(@imei, @identity_key)

    [
      service: context.service,
      identity_key: @identity_key,
      devices: [
        %{
          identity_digest: identity_digest,
          token: context.admin,
          scope: context.scope,
          id: "configured-tracker",
          profile: TAT140.configured_profile()
        }
      ],
      clock: fn -> context.now end
    ]
  end

  defp packet do
    {:ok, fixture} =
      Wotex.JSON.decode(File.read!("../../test/fixtures/teltonika/codec8_extended.json"))

    [vector] = fixture["vectors"]
    {:ok, packet} = vector["hex"] |> Base.decode16!() |> Codec8Extended.decode_frame()
    packet
  end

  defp fail_after_operation do
    receive do
      {:"$gen_call", from, {:authorized, _access, _permission, _activity, _now}} ->
        GenServer.reply(from, :ok)
        fail_after_operation()

      {:"$gen_call", from, {:operation, _scope, _principal, _operation, _now}} ->
        GenServer.reply(from, {:error, :not_found})
    end
  end

  defp cellular_document(context, packet) do
    {:ok, identity_digest} = TCPSession.identity_digest(@imei, @identity_key)

    frame_digest =
      :crypto.hash(:sha256, ["wtr.teltonika-frame.v1:", identity_digest, packet.frame])
      |> Base.encode16(case: :lower)

    {:ok, observation} =
      Observation.new(%{
        id: "teltonika-frame-" <> frame_digest,
        observed_at: context.now,
        ingress: "cellular",
        source: %{"adapter" => "teltonika-tcp", "device" => "configured-tracker"},
        addressing: %{"identity_digest" => identity_digest},
        payload: {:bytes, packet.frame},
        radio: %{},
        transport: %{
          "codec" => packet.codec,
          "record_count" => packet.record_count,
          "acknowledgement" => "durable-record-count"
        },
        provenance: %{
          "protocol" => "teltonika-codec8-extended",
          "revision" => "1.0.0",
          "configured_profile" => TAT140.configured_profile(),
          "identity_assurance" => "configured-routing-identifier"
        }
      })

    {:ok, document} = Observation.to_map(observation)
    document
  end
end
