defmodule Wotex.Tracker.Nerves.QemuFixture do
  @moduledoc """
  Prepares the isolated configuration used by the QEMU software-boot image.

  On the first virtual boot, `prepare/1` creates a private service directory,
  data directory, and random private probe credential. The same virtual disk
  retains them for the reboot probe. `verify/0` reports only whether the private
  SQLite file, guest-loopback health endpoint, deterministic TAT140 cellular
  peer and one closed native-resource sample are present. This fixture is absent
  from Pi firmware profiles.
  """

  import Bitwise
  require Logger
  alias Wotex.Tracker.Nerves.StoragePolicy
  alias Wotex.Tracker.Nerves.Supervisor, as: HostSupervisor
  alias Wotex.Tracker.Protocols.Teltonika.{TAT140, TCPSession}
  alias Wotex.Tracker.Service.{Codec, Credentials}
  alias Wotex.Tracker.Service.Cellular.Server, as: CellularServer
  alias Wotex.Tracker.Service.HTTP.Server

  @root "/root/tracker"
  @probe_token "qemu-probe.token"
  @cellular_config "cellular.json"
  @imei "123456789012345"
  @frame Base.decode16!(
           "00000000000000788E020000018BCFE73CC0010ABA9500232AAF80002A005A08002400190006000200F001001D570004001900F300430DFC005601C801CF002A0000000000000000018BCFE82720010ABA9500232AAF80002A005A08002401CF0005000100F000000400197FFF00430DF20056FFFF01CFBEEF000000000000020000F6CD"
         )
  @probe_attempts 50
  @probe_interval_ms 100

  def prepare(root \\ @root) do
    case File.lstat(root) do
      {:error, :enoent} -> create(root)
      {:ok, _} -> :ok
      _ -> {:error, :invalid_configuration}
    end
  rescue
    _ -> {:error, :invalid_configuration}
  end

  def verify do
    {:ok, _} =
      Task.start(fn ->
        case probe() do
          :ok ->
            Logger.info(
              "QEMU boot probe passed: private store, loopback HTTP, TAT140 cellular peer " <>
                "and durable replay, native resources, initialized storage marker"
            )

          :error ->
            Logger.error("QEMU boot probe failed")
        end
      end)

    :ok
  end

  @doc false
  def probe(options \\ [])

  def probe(options) when is_list(options) do
    regular? = Keyword.get(options, :regular?, &default_store?/0)
    initialized? = Keyword.get(options, :initialized?, &default_storage_initialized?/0)
    health = Keyword.get(options, :health, &default_health/0)
    ingress = Keyword.get(options, :ingress, &default_ingress/0)
    history = Keyword.get(options, :history, &default_history/0)
    attempts = Keyword.get(options, :attempts, @probe_attempts)
    interval = Keyword.get(options, :interval_ms, @probe_interval_ms)

    with true <- is_function(regular?, 0) and regular?.(),
         true <- is_function(initialized?, 0) and initialized?.(),
         true <- is_function(health, 0),
         :ok <- health.(),
         true <- is_function(ingress, 0),
         :ok <- ingress.(),
         true <- is_function(history, 0),
         true <- is_integer(attempts) and attempts in 1..@probe_attempts,
         true <- is_integer(interval) and interval in 0..@probe_interval_ms,
         :ok <- await_native(history, attempts, interval) do
      :ok
    else
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  def probe(_), do: :error

  defp create(root) do
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    data = Path.join(root, "data")
    File.mkdir!(data)
    File.chmod!(data, 0o700)
    token = Credentials.generate_token()
    {:ok, digest} = Credentials.token_digest(token)

    document = %{
      "schema" => "wtr.host.v1",
      "instance_id" => "qemu-smoke",
      "secret_key" => Base.encode64(:crypto.strong_rand_bytes(32)),
      "contract" => "teltonika.tat140.codec8e",
      "data_directory" => data,
      "listen" => %{"ip" => "127.0.0.1", "port" => 4000},
      "exposure" => "loopback",
      "public_origin" => "listener",
      "credentials" => [
        %{
          "id" => "qemu-only",
          "principal" => "smoke",
          "token_sha256" => digest,
          "grants" => %{"smoke" => ["read", "ingest"]},
          "expires_at" => 4_102_444_800_000
        }
      ]
    }

    write_private(root, "config.json", Codec.encode!(document))
    token_temporary = Path.join(root, @probe_token <> ".tmp")
    File.write!(token_temporary, token <> "\n")
    File.chmod!(token_temporary, 0o600)
    File.rename!(token_temporary, Path.join(root, @probe_token))
    identity_key = :crypto.strong_rand_bytes(32)
    {:ok, identity_digest} = TCPSession.identity_digest(@imei, identity_key)

    cellular = %{
      "schema" => "wtr.cellular-host.v1",
      "transport" => "clear_tcp",
      "listen" => %{"ip" => "127.0.0.1", "port" => 0},
      "identity_key" => Base.encode64(identity_key),
      "devices" => [
        %{
          "identity_digest" => identity_digest,
          "token" => token,
          "scope" => "smoke",
          "id" => "qemu-tat140",
          "profile" => TAT140.configured_profile()
        }
      ]
    }

    write_private(root, @cellular_config, Codec.encode!(cellular))
    {:ok, _marker} = StoragePolicy.provision(root, root, "qemu-smoke")
    :ok
  end

  defp write_private(root, name, bytes) do
    temporary = Path.join(root, name <> ".tmp")
    File.write!(temporary, bytes)
    File.chmod!(temporary, 0o600)
    File.rename!(temporary, Path.join(root, name))
  end

  defp default_store?, do: File.regular?(Path.join(@root, "data/tracker.db"))

  defp default_storage_initialized?,
    do: StoragePolicy.initialized?(@root, "qemu-smoke", Path.join(@root, "data"))

  defp default_health do
    url = ~c"http://127.0.0.1:4000/health/live"

    case :httpc.request(:get, {url, []}, [timeout: 2_000], body_format: :binary) do
      {:ok, {{_, 200, _}, _, _}} -> :ok
      _ -> :error
    end
  end

  defp default_ingress do
    with {:probe_token, {:ok, token}} <- {:probe_token, probe_token()},
         {:cellular_listener, {:ok, listener}} <- {:cellular_listener, cellular_listener()},
         {:codec8e_ack, :ok} <- {:codec8e_ack, submit_frame(listener)},
         {:durable_observation, {:ok, observation_id}} <-
           {:durable_observation, only_observation(token)},
         {:public_state, {:ok, state}} <- {:public_state, fixture_state(token, observation_id)},
         {:tracking_values, true} <- {:tracking_values, expected_tracking_state?(state)} do
      :ok
    else
      {stage, _} ->
        Logger.error("QEMU TAT140 probe failed at #{stage}")
        :error
    end
  end

  defp probe_token do
    path = Path.join(@root, @probe_token)

    with {:ok, %{type: :regular, links: 1, size: 44, mode: mode}} <- File.lstat(path),
         true <- (mode &&& 0o777) == 0o600,
         {:ok, <<token::binary-size(43), "\n">>} <-
           File.open(path, [:read, :binary], &IO.binread(&1, 45)),
         {:ok, _digest} <- Credentials.token_digest(token) do
      {:ok, token}
    else
      _ -> :error
    end
  end

  defp cellular_listener do
    case List.keyfind(Supervisor.which_children(HostSupervisor), CellularServer, 0) do
      {CellularServer, listener, :supervisor, _} when is_pid(listener) -> {:ok, listener}
      _ -> :error
    end
  catch
    :exit, _ -> :error
  end

  defp submit_frame(listener) do
    with {:ok, {{127, 0, 0, 1}, port}} <- CellularServer.listener_info(listener),
         {:ok, socket} <-
           :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, nodelay: true], 2_000) do
      result =
        with :ok <- :gen_tcp.send(socket, <<byte_size(@imei)::unsigned-big-16, @imei::binary>>),
             {:ok, <<1>>} <- :gen_tcp.recv(socket, 1, 2_000),
             :ok <- :gen_tcp.send(socket, @frame),
             {:ok, <<0, 0, 0, 2>>} <- :gen_tcp.recv(socket, 4, 2_000) do
          :ok
        else
          _ -> :error
        end

      :gen_tcp.close(socket)
      result
    else
      _ -> :error
    end
  end

  defp only_observation(token) do
    url = ~c"http://127.0.0.1:4000/api/v1/scopes/smoke/observations?limit=2"

    case :httpc.request(:get, {url, request_headers(token)}, [timeout: 2_000],
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _, response}} ->
        with {:ok, %{"generation" => "1", "items" => [%{"id" => id}]}} <- decode_data(response),
             true <- is_binary(id),
             do: {:ok, id},
             else: (_ -> :error)

      _ ->
        :error
    end
  end

  defp fixture_state(token, observation_id) do
    encoded = URI.encode(observation_id, &URI.char_unreserved?/1)
    url = String.to_charlist("http://127.0.0.1:4000/api/v1/scopes/smoke/state/" <> encoded)

    case :httpc.request(:get, {url, request_headers(token)}, [timeout: 2_000],
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _, response}} -> decode_data(response)
      _ -> :error
    end
  end

  defp request_headers(token),
    do: [
      {~c"accept", ~c"application/json"},
      {~c"authorization", String.to_charlist("Bearer " <> token)}
    ]

  defp decode_data(response) do
    case Codec.decode(response) do
      {:ok, %{"data" => data}} -> {:ok, data}
      _ -> :error
    end
  end

  defp expected_tracking_state?(%{"value" => %{"records" => [moving, stopped]}}) do
    measurement?(moving, "motion", true) and
      measurement?(moving, "batteryVoltage", 3.58) and
      measurement?(moving, "bleSensorTemperature", 24.3) and
      measurement?(moving, "bleSensorBatteryLevel", 87) and
      measurement?(moving, "bleSensorHumidity", 45.6) and
      measurement?(moving, "bleSensorMovementCount", 42) and
      position?(moving, 59.0, 18.0) and
      measurement?(stopped, "motion", false) and
      measurement?(stopped, "batteryVoltage", 3.57) and
      unavailable?(stopped, "bleSensorTemperature", "sensor_not_found") and
      unavailable?(stopped, "bleSensorHumidity", "sensor_not_found") and
      unavailable?(stopped, "bleSensorMovementCount", "sensor_lost") and
      stopped["positions"] != []
  end

  defp expected_tracking_state?(_), do: false

  defp measurement?(%{"measurements" => measurements}, kind, value) when is_list(measurements),
    do: Enum.any?(measurements, &(&1["kind"] == kind and get_in(&1, ["value", "value"]) == value))

  defp measurement?(_, _, _), do: false

  defp unavailable?(%{"measurements" => measurements}, kind, reason) when is_list(measurements),
    do:
      Enum.any?(
        measurements,
        &(&1["kind"] == kind and &1["availability"] == "unavailable" and
            &1["reason"] == reason)
      )

  defp unavailable?(_, _, _), do: false

  defp position?(%{"positions" => [position]}, latitude, longitude),
    do:
      get_in(position, ["latitude", "value"]) == latitude and
        get_in(position, ["longitude", "value"]) == longitude

  defp position?(_, _, _), do: false

  defp default_history do
    with {:ok, server} <- Server.child(HostSupervisor, Server),
         do: Server.operational_history(server, event: "native.sample")
  end

  defp await_native(_history, 0, _interval), do: :error

  defp await_native(history, attempts, interval) do
    case history.() do
      {:ok, %{"samples" => [_ | _]}} ->
        :ok

      _ ->
        Process.sleep(interval)
        await_native(history, attempts - 1, interval)
    end
  end
end
