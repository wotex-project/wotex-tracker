defmodule Wotex.Tracker.Nerves.QemuFixture do
  @moduledoc """
  Prepares the isolated configuration used by the QEMU software-boot image.

  On the first virtual boot, `prepare/1` creates a private service directory,
  data directory, and random private probe credential. The same virtual disk
  retains them for the reboot probe. `verify/0` reports only whether the private
  SQLite file, guest-loopback health endpoint, authenticated deterministic
  fixture ingress and one closed native-resource sample are present. This
  fixture is absent from Pi firmware profiles.
  """

  import Bitwise
  require Logger
  alias Wotex.Tracker.Nerves.StoragePolicy
  alias Wotex.Tracker.Nerves.Supervisor, as: HostSupervisor
  alias Wotex.Tracker.Service.{Codec, Credentials}
  alias Wotex.Tracker.Service.HTTP.Server

  @root "/root/tracker"
  @probe_token "qemu-probe.token"
  @operation "00000000-0000-4000-8000-000000000014"
  @payload "BRL8U5TDfAAE//wEDKw2QgDNy7gzTIhP"
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
              "QEMU boot probe passed: private store, loopback HTTP, authenticated fixture " <>
                "ingress, native resources, initialized storage marker"
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

    temporary = Path.join(root, "config.json.tmp")
    File.write!(temporary, Codec.encode!(document))
    File.chmod!(temporary, 0o600)
    File.rename!(temporary, Path.join(root, "config.json"))
    token_temporary = Path.join(root, @probe_token <> ".tmp")
    File.write!(token_temporary, token <> "\n")
    File.chmod!(token_temporary, 0o600)
    File.rename!(token_temporary, Path.join(root, @probe_token))
    {:ok, _marker} = StoragePolicy.provision(root, root, "qemu-smoke")
    :ok
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
    with {:ok, token} <- probe_token(),
         {:ok, receipt} <- import_fixture(token),
         observation_id when is_binary(observation_id) <-
           get_in(receipt, ["data", "observation_id"]),
         {:ok, state} <- fixture_state(token, observation_id),
         true <- expected_temperature?(state) do
      :ok
    else
      _ -> :error
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

  defp import_fixture(token) do
    body =
      Codec.encode!(%{
        "observation" => %{
          "schema" => "wtr.observation.v1",
          "id" => "qemu-private-ruuvi",
          "observed_at" => 1_700_000_000_000,
          "ingress" => "ble",
          "source" => %{"kind" => "qemu-software-peer"},
          "addressing" => %{"mac" => "qemu-private-address"},
          "radio" => %{},
          "transport" => %{"manufacturer_id" => 1_177},
          "provenance" => %{"kind" => "deterministic-qemu-fixture"},
          "payload" => %{"kind" => "bytes", "encoding" => "base64", "data" => @payload}
        },
        "expected_generation" => "0"
      })

    url = ~c"http://127.0.0.1:4000/api/v1/scopes/smoke/observations"
    headers = request_headers(token) ++ [{~c"idempotency-key", String.to_charlist(@operation)}]

    case :httpc.request(
           :post,
           {url, headers, ~c"application/json", body},
           [timeout: 2_000],
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _, response}} -> decode_data(response)
      _ -> :error
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

  defp expected_temperature?(%{"value" => %{"measurements" => measurements}})
       when is_list(measurements) do
    Enum.any?(measurements, fn
      %{"kind" => "temperature", "value" => %{"type" => "number", "value" => 24.3}} -> true
      _ -> false
    end)
  end

  defp expected_temperature?(_), do: false

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
