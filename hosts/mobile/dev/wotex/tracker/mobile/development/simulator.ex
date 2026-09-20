defmodule Wotex.Tracker.Mobile.Development.Simulator do
  @moduledoc """
  Bootable local composition of the mobile host and deterministic native peers.

  The composition starts the real loopback endpoint, cache, credential manager,
  notification registrar and root-screen callbacks. Only the remote service and
  iOS capabilities are simulated, through the same closed seams used in the
  packaged application. It is not compiled into production builds.
  """

  use Supervisor
  import Bitwise

  alias Wotex.Tracker.Mobile.{Config, CredentialManager, Host, NotificationRegistration, Runtime}

  alias Wotex.Tracker.Mobile.Development.{
    NativeSimulator,
    RemoteService,
    ScreenSimulator
  }

  @keys ~w(directory name port)a
  @requests [
    scan: "123e4567-e89b-42d3-a456-426614174001",
    connect: "123e4567-e89b-42d3-a456-426614174002",
    discover: "123e4567-e89b-42d3-a456-426614174003",
    read: "123e4567-e89b-42d3-a456-426614174004",
    write: "123e4567-e89b-42d3-a456-426614174005",
    disconnect: "123e4567-e89b-42d3-a456-426614174006",
    stop_scan: "123e4567-e89b-42d3-a456-426614174007"
  ]
  @peripheral "123e4567-e89b-12d3-a456-426614174000"
  @service "180a"
  @characteristic "2a29"

  @doc "Starts the finite simulator around one existing private data directory."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options) when is_list(options) do
    name = Keyword.get(options, :name, __MODULE__)

    with true <- valid_options?(options),
         true <- is_atom(name),
         {:ok, directory} <- directory(Keyword.get(options, :directory)),
         {:ok, port} <- port(Keyword.get(options, :port)) do
      Supervisor.start_link(__MODULE__, {directory, port}, name: name)
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  def start_link(_), do: {:error, :invalid_configuration}

  @doc "Allocates one currently free numeric loopback port for local development."
  @spec available_port() :: {:ok, :inet.port_number()} | {:error, :unavailable}
  def available_port do
    with {:ok, socket} <-
           :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: false]),
         {:ok, {{127, 0, 0, 1}, port}} <- :inet.sockname(socket),
         :ok <- :gen_tcp.close(socket) do
      {:ok, port}
    else
      _ -> {:error, :unavailable}
    end
  end

  @doc "Returns the local bootstrap URL and fixed simulator sign-in credential."
  @spec connection() :: map() | {:error, :unavailable}
  def connection do
    session = Runtime.web_session()
    target = Wotex.Tracker.Mobile.WebSession.target(session)
    Map.merge(RemoteService.credential(), %{bootstrap_url: target.url, origin: session.origin})
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc "Reports only bounded, redacted state from every simulated boundary."
  @spec status() :: map()
  def status do
    connection =
      case connection() do
        %{origin: origin} -> %{origin: origin}
        {:error, _} = error -> error
      end

    %{
      connection: connection,
      credentials: CredentialManager.status(Wotex.Tracker.Mobile.CredentialManager),
      native: NativeSimulator.status(),
      notifications: NotificationRegistration.status(Wotex.Tracker.Mobile.NotificationRegistration),
      remote: RemoteService.status(),
      screen: ScreenSimulator.status()
    }
  end

  @doc "Runs one deterministic native capability walkthrough through the root screen."
  @spec exercise() :: :ok | {:error, :unavailable}
  def exercise do
    with :ok <- NativeSimulator.emit(:offline),
         :ok <- NativeSimulator.emit(:online),
         :ok <- NativeSimulator.emit(:background),
         :ok <- NativeSimulator.emit(:active),
         :ok <- ScreenSimulator.blocked("https://example.com/mobile-simulator"),
         :ok <- ScreenSimulator.message(scan_command()),
         :ok <- ScreenSimulator.message(peripheral_command("connect", @requests[:connect])),
         :ok <- ScreenSimulator.message(discover_command()),
         :ok <- ScreenSimulator.message(characteristic_command("read", @requests[:read])),
         :ok <- ScreenSimulator.message(write_command()),
         :ok <-
           ScreenSimulator.message(peripheral_command("disconnect", @requests[:disconnect])),
         :ok <- ScreenSimulator.message(base_command(@requests[:stop_scan], "stop_scan")),
         :ok <- ScreenSimulator.message(share_request()),
         :ok <- NativeSimulator.emit({:notification, "development-alert"}) do
      :ok
    else
      _ -> {:error, :unavailable}
    end
  end

  @impl true
  def init({directory, port}) do
    options = [
      directory: directory,
      remote_origin: "https://mobile-simulator.invalid",
      port: port,
      secret_key_base: Base.encode64(:crypto.strong_rand_bytes(64)),
      capability: Config.generate_capability(),
      remote_transport: {RemoteService, RemoteService},
      secure_store: {Wotex.Mobile.SecureStore, NativeSimulator},
      notification_app_id: "org.wotex.tracker",
      notification_environment: "sandbox"
    ]

    case Config.new(options) do
      {:ok, config} ->
        children = [
          {NativeSimulator, []},
          {RemoteService, []},
          {Host, config},
          {ScreenSimulator, session: config.web_session}
        ]

        Supervisor.init(children, strategy: :rest_for_one)

      {:error, _} ->
        :ignore
    end
  end

  defp directory(path) when is_binary(path) and byte_size(path) in 1..4_096 do
    with true <- Path.type(path) == :absolute and Path.expand(path) == path,
         {:ok, %{type: :directory, mode: mode}} <- File.lstat(path),
         true <- (mode &&& 0o777) == 0o700 do
      {:ok, path}
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  defp directory(_), do: {:error, :invalid_configuration}

  defp port(nil), do: available_port()
  defp port(value) when value in 1..65_535, do: {:ok, value}
  defp port(_), do: {:error, :invalid_configuration}

  defp valid_options?(options) do
    Keyword.keyword?(options) and length(options) == map_size(Map.new(options)) and
      Keyword.keys(options) -- @keys == []
  end

  defp base_command(request, operation),
    do: %{
      "schema" => "wtr.mobile-ble-central-command.v1",
      "request_id" => request,
      "operation" => operation
    }

  defp scan_command do
    Map.merge(base_command(@requests[:scan], "scan"), %{
      "service_uuids" => [@service],
      "timeout_ms" => 1_000
    })
  end

  defp peripheral_command(operation, request),
    do: Map.put(base_command(request, operation), "peripheral_id", @peripheral)

  defp discover_command do
    Map.put(peripheral_command("discover", @requests[:discover]), "service_uuids", [@service])
  end

  defp characteristic_command(operation, request) do
    Map.merge(peripheral_command(operation, request), %{
      "service_uuid" => @service,
      "characteristic_uuid" => @characteristic
    })
  end

  defp write_command do
    Map.merge(characteristic_command("write", @requests[:write]), %{
      "encoding" => "base64url",
      "value" => Base.url_encode64(<<9, 8, 7>>, padding: false)
    })
  end

  defp share_request do
    %{
      "schema" => "wtr.mobile-share.v1",
      "filename" => "wotex-route-page.json",
      "media_type" => "application/json",
      "content" => Jason.encode!(%{"schema" => "wtr.route-page-export.v1"})
    }
  end
end
