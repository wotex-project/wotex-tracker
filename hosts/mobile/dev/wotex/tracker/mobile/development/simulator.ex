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

  alias Wotex.Tracker.Protocols.Teltonika.EYESensorConfiguration

  alias Wotex.Tracker.Mobile.{Config, CredentialManager, Host, NotificationRegistration, Runtime}

  alias Wotex.Tracker.Mobile.Development.{
    APNsSimulator,
    NativeSimulator,
    RemoteService,
    ScreenSimulator
  }

  @keys ~w(directory name port)a
  @requests [
    scan: "123e4567-e89b-42d3-a456-426614174001",
    connect: "123e4567-e89b-42d3-a456-426614174002",
    discover: "123e4567-e89b-42d3-a456-426614174003",
    authenticate: "123e4567-e89b-42d3-a456-426614174004",
    sensor_mask: "123e4567-e89b-42d3-a456-426614174005",
    save: "123e4567-e89b-42d3-a456-426614174006",
    verify: "123e4567-e89b-42d3-a456-426614174007",
    disconnect: "123e4567-e89b-42d3-a456-426614174008",
    stop_scan: "123e4567-e89b-42d3-a456-426614174009"
  ]
  @peripheral "123e4567-e89b-12d3-a456-426614174000"

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
      apns: APNsSimulator.status(),
      credentials: CredentialManager.status(Wotex.Tracker.Mobile.CredentialManager),
      native: NativeSimulator.status(),
      notifications:
        NotificationRegistration.status(Wotex.Tracker.Mobile.NotificationRegistration),
      remote: RemoteService.status(),
      screen: ScreenSimulator.status()
    }
  end

  @doc "Dispatches, delivers and opens one provider notification in a selected app state."
  @spec notify(String.t(), :cold | :warm | :background) ::
          {:ok, String.t()} | {:error, atom()} | {:retry, atom()}
  def notify(event_reference, launch_state)
      when launch_state in [:cold, :warm, :background] do
    with {:accepted, receipt} <- RemoteService.dispatch_notification(event_reference),
         :ok <- APNsSimulator.deliver(receipt),
         :ok <- APNsSimulator.tap(receipt, launch_state) do
      {:ok, receipt}
    end
  end

  def notify(_, _), do: {:error, :invalid_notification}

  @doc "Runs one deterministic native capability walkthrough through the root screen."
  @spec exercise() :: :ok | {:error, :unavailable}
  def exercise do
    with :ok <- NativeSimulator.emit(:offline),
         :ok <- NativeSimulator.emit(:online),
         :ok <- NativeSimulator.emit(:background),
         :ok <- NativeSimulator.emit(:active),
         :ok <- ScreenSimulator.blocked("https://example.com/mobile-simulator"),
         :ok <- ScreenSimulator.message(scan_command()),
         :ok <- ScreenSimulator.message(target_command(:connect_command, @requests[:connect])),
         :ok <- ScreenSimulator.message(discover_command()),
         :ok <- ScreenSimulator.message(authenticate_command()),
         :ok <- ScreenSimulator.message(sensor_mask_command()),
         :ok <- ScreenSimulator.message(save_command()),
         :ok <- ScreenSimulator.message(verify_command()),
         :ok <-
           ScreenSimulator.message(target_command(:disconnect_command, @requests[:disconnect])),
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
          {APNsSimulator, delivery: {ScreenSimulator, ScreenSimulator}},
          {RemoteService, apns: {APNsSimulator, APNsSimulator}},
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
    command!(EYESensorConfiguration.scan_command(@requests[:scan], 1_000))
  end

  defp discover_command do
    command!(EYESensorConfiguration.discover_command(@requests[:discover], @peripheral))
  end

  defp authenticate_command,
    do:
      command!(
        EYESensorConfiguration.authenticate_command(
          @requests[:authenticate],
          @peripheral,
          "123456"
        )
      )

  defp sensor_mask_command,
    do:
      command!(
        EYESensorConfiguration.sensor_mask_command(
          @requests[:sensor_mask],
          @peripheral,
          [:temperature, :humidity, :magnetic, :movement]
        )
      )

  defp save_command,
    do: command!(EYESensorConfiguration.save_command(@requests[:save], @peripheral))

  defp verify_command,
    do: command!(EYESensorConfiguration.read_sensor_mask_command(@requests[:verify], @peripheral))

  defp target_command(function, request),
    do: command!(apply(EYESensorConfiguration, function, [request, @peripheral]))

  defp command!({:ok, command}), do: command

  defp share_request do
    %{
      "schema" => "wtr.mobile-share.v1",
      "filename" => "wotex-route-page.json",
      "media_type" => "application/json",
      "content" => Jason.encode!(%{"schema" => "wtr.route-page-export.v1"})
    }
  end
end
