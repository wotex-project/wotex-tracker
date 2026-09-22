defmodule Wotex.Tracker.Host.UIDevelopment do
  @moduledoc false

  alias Wotex.Tracker.Observation
  alias Wotex.Tracker.Protocols.Teltonika.{ATC700, TAT140}
  alias Wotex.Tracker.Host.{Browser, BrowserConfig, Supervisor}
  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.{Credentials, Identifier}
  alias Wotex.Tracker.Service.HTTP.{Config, Server}
  alias Wotex.Tracker.UI.MapPack

  def run do
    ensure_apps!()
    port = available_port!()
    origin = "http://127.0.0.1:#{port}"
    directory = development_directory!()
    token = Credentials.generate_token()
    credentials = credentials!(token)
    device = development_device!()
    {:ok, map_pack} = MapPack.new(development_map_pack())

    service_options = [
      directory: directory,
      credentials: credentials,
      ip: {127, 0, 0, 1},
      port: 0,
      public_origin: :listener,
      exposure: :loopback,
      contract: device.contract,
      cellular_ingress: :configured
    ]

    browser = %BrowserConfig{
      ip: {127, 0, 0, 1},
      port: port,
      public_origin: origin,
      exposure: :loopback,
      tls: nil,
      secret_key_base: Base.encode64(:crypto.strong_rand_bytes(64)),
      prompt: nil,
      map_pack: map_pack
    }

    {:ok, host} =
      Supervisor.start_link(service: service_options, browser: browser, native_resource: nil)

    {:ok, api} = Server.child(host, Server)
    {:ok, config} = Config.new(service_options)
    {:ok, service} = Server.context(api, config)
    thing = seed!(service, token, device)
    {:ok, {{127, 0, 0, 1}, ^port}} = Browser.Endpoint.server_info(:http)

    IO.puts("WOTEX_UI_ORIGIN=#{origin}")
    IO.puts("WOTEX_UI_SCOPE=workshop")
    IO.puts("WOTEX_UI_TOKEN=#{token}")
    IO.puts("WOTEX_UI_THING=#{thing}")
    IO.puts("WOTEX_UI_DEVICE=#{device.name}")

    IO.puts(
      "WOTEX_UI_PROVISIONING=#{origin}/assets/#{URI.encode(thing, &URI.char_unreserved?/1)}/provisioning?device=#{device.name}"
    )

    IO.puts("WOTEX_UI_READY=1")

    receive do
      :stop -> :ok
    end
  end

  defp ensure_apps! do
    for application <- [:inets, :ssl, :wotex_tracker_service, :wotex_tracker_ui] do
      {:ok, _} = Application.ensure_all_started(application)
    end
  end

  defp available_port! do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: false])

    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp development_directory! do
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

    path =
      Path.expand(
        "_build/ui-development/#{nonce}",
        File.cwd!()
      )

    :ok = File.mkdir_p(path)
    :ok = File.chmod(path, 0o700)
    System.at_exit(fn _ -> File.rm_rf(path) end)
    path
  end

  defp credentials!(token) do
    {:ok, digest} = Credentials.token_digest(token)

    {:ok, credentials} =
      Credentials.new(%{
        instance_id: "ui-development",
        secret_key: :crypto.strong_rand_bytes(32),
        entries: [
          %{
            id: "development-owner",
            principal: "development-owner",
            token_sha256: digest,
            grants: %{"workshop" => ~w(read raw ingest enroll admin)},
            expires_at: System.system_time(:millisecond) + 86_400_000
          }
        ]
      })

    credentials
  end

  defp development_map_pack do
    %{
      "schema" => "wtr.map-pack.v1",
      "id" => "stockholm-development",
      "revision" => "1",
      "attribution" => "Deterministic development fixture — not navigation data",
      "coverage" => %{"west" => 17.4, "south" => 58.4, "east" => 18.6, "north" => 59.6},
      "features" => [
        %{
          "class" => "water",
          "points" => [[58.5, 17.62], [58.78, 17.76], [59.02, 17.72], [59.45, 17.9]]
        },
        %{
          "class" => "boundary",
          "points" => [[58.62, 17.48], [58.9, 18.02], [59.42, 18.48]]
        },
        %{
          "class" => "road",
          "points" => [
            [58.55, 17.72],
            [58.82, 17.9],
            [59.0, 18.0],
            [59.34, 18.24],
            [59.48, 18.42]
          ]
        },
        %{
          "class" => "road",
          "points" => [
            [58.65, 18.42],
            [58.9, 18.18],
            [59.0, 18.0],
            [59.25, 17.82],
            [59.46, 17.66]
          ]
        }
      ]
    }
  end

  defp development_device! do
    case System.get_env("WOTEX_UI_DEVICE", "tat140") do
      "tat140" ->
        %{
          name: "tat140",
          contract: :teltonika_tat140_codec8e,
          fixture: "tat140_ble_sensor.json",
          observation_id: "ui-development-tat140",
          source_device: "development-tat140",
          configured_profile: TAT140.configured_profile(),
          title: "Cargo bike tracker"
        }

      "atc700" ->
        %{
          name: "atc700",
          contract: :teltonika_atc700_codec8e,
          fixture: "atc700_demo.json",
          observation_id: "ui-development-atc700",
          source_device: "development-atc700",
          configured_profile: ATC700.configured_profile(),
          title: "Development ATC700"
        }

      _ ->
        raise "WOTEX_UI_DEVICE accepts only tat140 or atc700"
    end
  end

  defp seed!(service, token, device) do
    now = System.system_time(:millisecond)

    fixture_path =
      Path.expand("../../../test/fixtures/teltonika/#{device.fixture}", __DIR__)

    {:ok, fixture} = fixture_path |> File.read!() |> Wotex.JSON.decode()
    [vector] = fixture["vectors"]
    frame = Base.decode16!(vector["hex"])
    <<_::binary-size(9), record_count, _::binary>> = frame

    {:ok, observation} =
      Observation.new(%{
        id: device.observation_id,
        observed_at: now,
        ingress: "cellular",
        source: %{"adapter" => "teltonika-tcp", "device" => device.source_device},
        addressing: %{"identity_digest" => String.duplicate("a", 64)},
        payload: {:bytes, frame},
        radio: %{},
        transport: %{"codec" => 0x8E, "record_count" => record_count},
        provenance: %{
          "protocol" => "teltonika-codec8-extended",
          "configured_profile" => device.configured_profile,
          "identity_assurance" => "configured-routing-identifier"
        }
      })

    {:ok, observation_document} = Observation.to_map(observation)

    {:ok, imported} =
      Service.submit(
        service,
        token,
        "workshop",
        Identifier.uuid(),
        %{"observation" => observation_document, "expected_generation" => "0"},
        now
      )

    {:ok, enrolled} =
      Service.enroll(
        service,
        token,
        "workshop",
        Identifier.uuid(),
        %{
          "observation_id" => imported["data"]["observation_id"],
          "title" => device.title,
          "owner_confirmed" => true,
          "expected_generation" => "1"
        },
        now
      )

    thing = enrolled["data"]["thing_id"]

    {:ok, %{"outcome" => "committed"}} =
      Service.materialize(
        service,
        token,
        "workshop",
        Identifier.uuid(),
        %{"thing_id" => thing, "expected_generation" => "2"},
        now
      )

    thing
  end
end

Wotex.Tracker.Host.UIDevelopment.run()
