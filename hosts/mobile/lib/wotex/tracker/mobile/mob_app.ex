defmodule Wotex.Tracker.Mobile.MobApp do
  @moduledoc """
  Native BEAM entry point for the local shared LiveView shell.

  A first run presents a native, non-secret service-origin setup. Later starts
  reconstruct an ephemeral loopback host from that private selection. No
  development distribution listener or cookie is started.
  """

  alias Wotex.Tracker.Mobile.{MobScreen, NativeBootstrap, WebSession}

  @doc "Installs explicit runtime options for the following native start."
  @spec configure(keyword()) :: :ok
  def configure(options) when is_list(options) do
    Application.put_env(:wotex_tracker_mobile, :host, options, persistent: true)
  end

  @doc "Starts the OTP application and its sole bridge-bearing root WebView."
  @spec start() :: {:ok, pid()} | {:error, term()}
  def start(options \\ []) when is_list(options) do
    install_logger = Keyword.get(options, :install_logger, &Mob.NativeLogger.install/0)

    start_application =
      Keyword.get(options, :start_application, fn ->
        Application.ensure_all_started(:wotex_tracker_mobile)
      end)

    start_registry = Keyword.get(options, :start_registry, &Mob.ComponentRegistry.start_link/0)
    bootstrap = Keyword.get(options, :bootstrap, &NativeBootstrap.boot/0)
    configure = Keyword.get(options, :configure, &NativeBootstrap.configure/1)

    start_root = Keyword.get(options, :start_root, &Mob.Screen.start_root(MobScreen, &1))

    with :ok <- invoke(install_logger),
         {:ok, _} <- invoke(start_application),
         :ok <- ensure_component_registry(invoke(start_registry)),
         {:ok, params} <- root_params(invoke(bootstrap), configure) do
      invoke(fn -> start_root.(params) end)
    else
      {:error, _} = error -> error
      _ -> {:error, :native_runtime_unavailable}
    end
  end

  defp ensure_component_registry({:ok, _}), do: :ok
  defp ensure_component_registry({:error, {:already_started, _}}), do: :ok
  defp ensure_component_registry({:error, _} = error), do: error
  defp ensure_component_registry(_), do: {:error, :native_runtime_unavailable}

  defp root_params({:ok, %WebSession{} = session}, _configure),
    do: {:ok, %{session: session}}

  defp root_params(:missing, configure) when is_function(configure, 1),
    do: {:ok, %{setup: configure}}

  defp root_params({:error, _} = error, _configure), do: error
  defp root_params(_, _), do: {:error, :native_runtime_unavailable}

  defp invoke(function) do
    function.()
  rescue
    _ -> {:error, :native_runtime_unavailable}
  catch
    _, _ -> {:error, :native_runtime_unavailable}
  end
end
