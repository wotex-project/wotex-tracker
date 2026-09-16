defmodule Wotex.Tracker.Nerves.QemuFixture do
  @moduledoc """
  Prepares the isolated configuration used by the QEMU software-boot image.

  On the first virtual boot, `prepare/1` creates a private service directory,
  data directory, and random credential digest without publishing a usable
  token. The same virtual disk retains them for the reboot probe. `verify/0`
  reports only whether the private SQLite file and guest-loopback health
  endpoint are present. This fixture is absent from Pi firmware profiles.
  """

  require Logger
  alias Wotex.Tracker.Service.{Codec, Credentials}

  @root "/root/tracker"

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
        url = ~c"http://127.0.0.1:4000/health/live"

        result =
          with true <- File.regular?(Path.join(@root, "data/tracker.db")),
               {:ok, {{_, 200, _}, _, _}} <-
                 :httpc.request(:get, {url, []}, [timeout: 2_000], body_format: :binary) do
            :ok
          else
            _ -> :error
          end

        case result do
          :ok -> Logger.info("QEMU boot probe passed: private store and loopback HTTP")
          :error -> Logger.error("QEMU boot probe failed")
        end
      end)

    :ok
  end

  defp create(root) do
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    data = Path.join(root, "data")
    File.mkdir!(data)
    File.chmod!(data, 0o700)
    {:ok, digest} = Credentials.generate_token() |> Credentials.token_digest()

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
          "grants" => %{"smoke" => ["read"]},
          "expires_at" => 4_102_444_800_000
        }
      ]
    }

    temporary = Path.join(root, "config.json.tmp")
    File.write!(temporary, Codec.encode!(document))
    File.chmod!(temporary, 0o600)
    File.rename!(temporary, Path.join(root, "config.json"))
    :ok
  end
end
