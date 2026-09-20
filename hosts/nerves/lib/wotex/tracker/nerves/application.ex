defmodule Wotex.Tracker.Nerves.Application do
  @moduledoc """
  Starts the Nerves Tracker service image and its optional control panel.

  The Pi images load private service and, when configured, browser files from
  the writable mount before supervision. The QEMU software-test target also
  prepares its isolated first-boot fixture and checks loopback service health.
  Startup does not turn the presence of a display into authority to enroll or
  access Tracker data.
  """

  use Application
  alias Wotex.Tracker.Nerves.{ClockPolicy, Config, FirmwareHealth, StoragePolicy}
  alias Wotex.Tracker.Nerves.Supervisor, as: HostSupervisor
  alias Wotex.Tracker.Service.Credentials

  @impl true
  def start(_type, _args) do
    with :ok <- prepare_target(),
         :ok <- StoragePolicy.require_marker(data_root()),
         {:ok, options} <-
           Config.load(
             Application.get_env(:wotex_tracker_nerves, :config_path),
             Application.get_env(:wotex_tracker_nerves, :data_root)
           ),
         {:ok, apns} <- apns_config(options),
         :ok <- ClockPolicy.admit(options, not is_nil(apns), &synchronized_clock?/0),
         instance_id = Credentials.instance_id(options[:credentials]),
         :ok <- StoragePolicy.admit(data_root(), instance_id, options[:directory]),
         {:ok, cellular} <- cellular_config(options),
         {:ok, browser} <- browser_config(options) do
      start_host(options, browser, cellular, apns, instance_id)
    end
  end

  defp start_host(options, browser, cellular, apns, instance_id) do
    case HostSupervisor.start_link(
           service: options,
           browser: browser,
           cellular: cellular,
           apns: apns
         ) do
      {:ok, host} -> finalize_host(host, instance_id, options[:directory])
      {:error, reason} -> recover_or_return(reason)
    end
  end

  defp finalize_host(host, instance_id, directory) do
    with :ok <- StoragePolicy.mark_initialized(data_root(), instance_id, directory),
         :ok <- target_ready(host, instance_id, directory) do
      {:ok, host}
    else
      {:error, _} = error ->
        Supervisor.stop(host)
        error
    end
  end

  defp recover_or_return(reason) do
    if StoragePolicy.recovery_failure?(reason),
      do: {:error, :recovery_required},
      else: {:error, reason}
  end

  defp data_root, do: Application.get_env(:wotex_tracker_nerves, :data_root)

  if Mix.target() == :qemu_aarch64 do
    alias Wotex.Tracker.Nerves.QemuFixture

    defp prepare_target, do: QemuFixture.prepare()

    defp target_ready(host, instance_id, directory) do
      with :ok <- FirmwareHealth.check(host, data_root(), instance_id, directory),
           do: QemuFixture.verify()
    end
  else
    defp prepare_target, do: :ok

    defp target_ready(host, instance_id, directory),
      do: FirmwareHealth.check(host, data_root(), instance_id, directory)
  end

  if Mix.target() == :host do
    defp synchronized_clock? do
      case Application.get_env(:wotex_tracker_nerves, :clock_synchronized) do
        provider when is_function(provider, 0) -> provider.()
        _ -> false
      end
    end
  else
    defp synchronized_clock?, do: NervesTime.synchronized?()
  end

  defp browser_config(options) do
    case Application.get_env(:wotex_tracker_nerves, :browser_config_path) do
      nil ->
        {:ok, nil}

      path ->
        module = Wotex.Tracker.Nerves.BrowserConfig

        if Code.ensure_loaded?(module) do
          :erlang.apply(module, :load, [
            path,
            Application.get_env(:wotex_tracker_nerves, :data_root),
            options
          ])
        else
          {:error, :ui_not_in_artifact}
        end
    end
  end

  defp cellular_config(options) do
    Config.load_cellular(
      Application.get_env(:wotex_tracker_nerves, :cellular_config_path),
      data_root(),
      options
    )
  end

  defp apns_config(options) do
    Config.load_apns(
      Application.get_env(:wotex_tracker_nerves, :apns_config_path),
      data_root(),
      options
    )
  end
end
