defmodule Wotex.Tracker.Service.ATC700WireContractTest do
  @moduledoc false
  use ExUnit.Case, async: false

  import Wotex.Tracker.Service.Fixtures

  alias Wotex.Tracker.Protocols.Teltonika.{ATC700, TCPSession}
  alias Wotex.Tracker.QuerySpec
  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.Cellular.Server
  alias Wotex.Tracker.Service.Identifier

  @imei "123456789012345"
  @identity_key :binary.copy(<<11>>, 32)

  setup do
    context = service()

    {:ok, service} =
      Service.new(%{
        store: context.store,
        credentials: context.credentials,
        base_url: "http://127.0.0.1:45678",
        contract: :teltonika_atc700_codec8e,
        cellular_ingress: :configured
      })

    {:ok, identity_digest} = TCPSession.identity_digest(@imei, @identity_key)

    server =
      start_supervised!(
        Supervisor.child_spec(
          {Server,
           service: service,
           identity_key: @identity_key,
           devices: [
             %{
               identity_digest: identity_digest,
               token: context.admin,
               scope: context.scope,
               id: "development-atc700",
               profile: ATC700.configured_profile()
             }
           ],
           ip: {127, 0, 0, 1},
           port: 0,
           clock: fn -> context.now end,
           login_timeout_ms: 1_000,
           frame_timeout_ms: 1_000,
           send_timeout_ms: 1_000,
           shutdown_timeout_ms: 1_000},
          id: make_ref(),
          restart: :temporary
        )
      )

    {:ok, {{127, 0, 0, 1}, port}} = Server.listener_info(server)
    frame = fixture_frame()

    Map.merge(context, %{service: service, server: server, port: port, frame: frame})
  end

  test "an ATC700 peer crosses IMEI, Codec 8E, ACK, durable map state and statistics", c do
    script = Path.expand("fixtures/teltonika_peer.escript", __DIR__)

    assert {"ok 84 cases\n", 0} =
             System.cmd(
               "escript",
               [
                 script,
                 "127.0.0.1",
                 Integer.to_string(c.port),
                 @imei,
                 Base.encode16(c.frame)
               ],
               stderr_to_stdout: true
             )

    assert {:ok, %{"generation" => "1", "items" => [%{"id" => observation_id}]}} =
             Service.list(
               c.service,
               c.admin,
               c.scope,
               "observations",
               %{"limit" => 10},
               c.now
             )

    assert {:ok, %{"value" => observation_state}} =
             Service.get(c.service, c.reader, c.scope, "state", observation_id, c.now)

    assert [%{"latitude" => %{"value" => 59.0}, "longitude" => %{"value" => 18.0}}] =
             observation_state["positions"]

    assert Enum.map(observation_state["measurements"], &{&1["kind"], &1["value"]["value"]}) == [
             {"motion", true},
             {"batteryVoltage", 3.6},
             {"batteryLevel", 72}
           ]

    assert {:ok, enrolled} =
             Service.enroll(
               c.service,
               c.admin,
               c.scope,
               Identifier.uuid(),
               %{
                 "observation_id" => observation_id,
                 "title" => "Development ATC700",
                 "owner_confirmed" => true,
                 "expected_generation" => "1"
               },
               c.now
             )

    thing = enrolled["data"]["thing_id"]

    assert {:ok, %{"generation" => "3"}} =
             Service.materialize(
               c.service,
               c.admin,
               c.scope,
               Identifier.uuid(),
               %{"thing_id" => thing, "expected_generation" => "2"},
               c.now
             )

    assert {:ok, %{"value" => thing_state}} =
             Service.get(c.service, c.reader, c.scope, "state", thing, c.now)

    assert thing_state["positions"] == observation_state["positions"]

    {:ok, query} =
      QuerySpec.new(%{
        id: "atc700-battery-level",
        revision: "wire-simulation-v1",
        dataset: :measurements,
        measurement: "batteryLevel",
        unit: "%",
        series: [thing],
        qualities: [:valid],
        from_at: c.now,
        to_at: c.now + 1_000,
        timezone: "Etc/UTC",
        bucket_ms: 1_000,
        aggregation: :last,
        order: :ascending,
        max_points: 1
      })

    {:ok, query_document} = QuerySpec.to_map(query)

    assert {:ok, statistics} =
             Service.analytics(c.service, c.reader, c.scope, query_document, c.now)

    assert statistics["qualified_rows"] == 1

    assert [
             %{
               "id" => ^thing,
               "points" => [%{"value" => 72, "sample_count" => 1}]
             }
           ] = statistics["series"]
  end

  defp fixture_frame do
    {:ok, fixture} =
      Wotex.JSON.decode(File.read!("../../test/fixtures/teltonika/atc700_demo.json"))

    [vector] = fixture["vectors"]
    frame = Base.decode16!(vector["hex"])
    assert Base.encode16(:crypto.hash(:sha256, frame), case: :lower) == vector["sha256"]
    frame
  end
end
