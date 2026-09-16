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
  alias Wotex.Tracker.Nerves.Config
  alias Wotex.Tracker.Nerves.Supervisor, as: HostSupervisor

  @impl true
  def start(_type, _args) do
    with :ok <- prepare_target(),
         {:ok, options} <-
           Config.load(
             Application.get_env(:wotex_tracker_nerves, :config_path),
             Application.get_env(:wotex_tracker_nerves, :data_root)
           ),
         {:ok, browser} <- browser_config(options) do
      case HostSupervisor.start_link(service: options, browser: browser) do
        {:ok, _} = started ->
          target_ready()
          started

        error ->
          error
      end
    end
  end

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
