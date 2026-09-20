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
  alias Wotex.Tracker.Nerves.{Config, StoragePolicy}
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
         instance_id = Credentials.instance_id(options[:credentials]),
         :ok <- StoragePolicy.admit(data_root(), instance_id, options[:directory]),
         {:ok, browser} <- browser_config(options) do
      start_host(options, browser, instance_id)
    end
  end

  defp start_host(options, browser, instance_id) do
    case HostSupervisor.start_link(service: options, browser: browser) do
      {:ok, host} -> finalize_host(host, instance_id, options[:directory])
      {:error, reason} -> recover_or_return(reason)
    end
  end

  defp finalize_host(host, instance_id, directory) do
    case StoragePolicy.mark_initialized(data_root(), instance_id, directory) do
      :ok ->
        target_ready()
        {:ok, host}

      {:error, :recovery_required} = error ->
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
    defp prepare_target, do: Wotex.Tracker.Nerves.QemuFixture.prepare()
    defp target_ready, do: Wotex.Tracker.Nerves.QemuFixture.verify()
  else
    defp prepare_target, do: :ok
    defp target_ready, do: :ok
  end

  defp browser_config(options) do
    case Application.get_env(:wotex_tracker_nerves, :browser_config_path) do
      nil ->
        {:ok, nil}

      path ->
        module = Wotex.Tracker.Nerves.BrowserConfig

        if Code.ensure_loaded?(module) do
          apply(module, :load, [
            path,
            Application.get_env(:wotex_tracker_nerves, :data_root),
            options
          ])
        else
          {:error, :ui_not_in_artifact}
        end
    end
  end
end
