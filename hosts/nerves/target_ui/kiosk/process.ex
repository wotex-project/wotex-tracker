defmodule Wotex.Tracker.Nerves.Kiosk.Process do
  @moduledoc false

  use Supervisor

  @bus "unix:path=/run/dbus-session-bus"

  def start_link(config), do: Supervisor.start_link(__MODULE__, config)

  @impl true
  def init(config) do
    Application.put_env(:myelin, :trusted_origins, [config.public_origin])
    Application.put_env(:myelin, :scripts, %{"keyboard" => %{enabled: true}})
    launch_url = Wotex.Tracker.Nerves.Browser.DeviceSession.launch_url(config.public_origin)

    env =
      [
        {"XDG_RUNTIME_DIR", "/run"},
        {"DBUS_SESSION_BUS_ADDRESS", @bus}
      ] ++ Myelin.browser_env()

    bus =
      Supervisor.child_spec(
        {MuonTrap.Daemon,
         [
           "dbus-daemon",
           ["--session", "--address=#{@bus}", "--nofork", "--syslog-only"],
           [stderr_to_stdout: true, log_output: :info, log_prefix: "dbus: "]
         ]},
        id: :dbus
      )

    cog =
      Supervisor.child_spec(
        {MuonTrap.Daemon,
         [
           "cog",
           ["--platform=drm", "--platform-params=renderer=gles", launch_url] ++
             Myelin.browser_args(),
           [
             env: env,
             stderr_to_stdout: true,
             log_output: :info,
             log_prefix: "cog: ",
             wait_for: &wait_for_bus/0
           ]
         ]},
        id: :cog
      )

    Supervisor.init([bus, cog], strategy: :rest_for_one, max_restarts: 2, max_seconds: 60)
  end

  defp wait_for_bus, do: wait_for_bus(20)
  defp wait_for_bus(0), do: raise("dbus session bus did not start")

  defp wait_for_bus(attempts) do
    if File.exists?("/run/dbus-session-bus") do
      :ok
    else
      Process.sleep(500)
      wait_for_bus(attempts - 1)
    end
  end
end
