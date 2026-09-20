defmodule Wotex.Tracker.Mobile.NativeAdapters do
  @moduledoc """
  Fixed native capability cohort used by the root mobile screen.

  Production always selects the packaged Mob and app-owned plugin modules.
  Development and test may select the one repository-owned simulator module
  when that module is present in the build. Page content cannot name or replace
  any adapter.
  """

  @development Wotex.Tracker.Mobile.Development.NativeSimulator
  @derive {Inspect, only: [:mode]}
  @enforce_keys [:mode, :ble, :device, :notifications, :permissions, :share, :webview]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          mode: :production | :development,
          ble: module(),
          device: module(),
          notifications: module(),
          permissions: module(),
          share: module(),
          webview: module()
        }

  @doc "Returns the exact packaged native cohort."
  @spec production() :: t()
  def production do
    %__MODULE__{
      mode: :production,
      ble: :wotex_ble_central_nif,
      device: Mob.Device,
      notifications: MobNotify,
      permissions: Mob.Permissions,
      share: Mob.Share,
      webview: Mob.WebView
    }
  end

  @doc "Returns the repository-owned simulator cohort only in dev/test builds."
  @spec development() :: {:ok, t()} | {:error, :simulator_unavailable}
  def development do
    module = @development

    if Code.ensure_loaded?(module) and function_exported?(module, :simulator?, 0) and
         module.simulator?() do
      {:ok,
       %__MODULE__{
         mode: :development,
         ble: @development,
         device: @development,
         notifications: @development,
         permissions: @development,
         share: @development,
         webview: @development
       }}
    else
      {:error, :simulator_unavailable}
    end
  end
end
