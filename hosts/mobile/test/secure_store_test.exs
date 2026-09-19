defmodule Wotex.Tracker.Mobile.SecureStoreTest do
  @moduledoc false

  use ExUnit.Case, async: true
  alias Wotex.Mobile.SecureStore

  defmodule Adapter do
    def fetch(key), do: Process.get({__MODULE__, key}, {:error, :not_found})

    def put(key, value) do
      Process.put({__MODULE__, key}, {:ok, value})
      :ok
    end

    def delete(key) do
      Process.delete({__MODULE__, key})
      :ok
    end
  end

  defmodule InvalidAdapter do
    def fetch(_), do: {:ok, String.duplicate("x", 4_097)}
    def put(_, _), do: :unexpected
    def delete(_), do: :unexpected
  end

  defmodule FailingAdapter do
    def fetch(_), do: raise("private secure-store failure")
    def put(_, _), do: throw(:private_secure_store_failure)
    def delete(_), do: exit(:private_secure_store_failure)
  end

  test "stores only bounded values in the two closed slots" do
    assert {:error, :not_found} = SecureStore.fetch(:credential, Adapter)
    assert :ok = SecureStore.put(:credential, "opaque-credential", Adapter)
    assert {:ok, "opaque-credential"} = SecureStore.fetch(:credential, Adapter)
    assert :ok = SecureStore.delete(:credential, Adapter)
    assert {:error, :not_found} = SecureStore.fetch(:credential, Adapter)

    assert :ok = SecureStore.put(:installation_id, "installation", Adapter)
    assert {:ok, "installation"} = SecureStore.fetch(:installation_id, Adapter)
  end

  test "rejects widened keys, malformed values and private adapter failures" do
    for key <- [:token, :password, "credential", nil] do
      assert {:error, :invalid_data} = SecureStore.fetch(key, Adapter)
      assert {:error, :invalid_data} = SecureStore.delete(key, Adapter)
    end

    for value <- ["", String.duplicate("x", 4_097), nil] do
      assert {:error, :invalid_data} = SecureStore.put(:credential, value, Adapter)
    end

    assert {:error, :unavailable} = SecureStore.fetch(:credential, InvalidAdapter)
    assert {:error, :unavailable} = SecureStore.put(:credential, "value", InvalidAdapter)
    assert {:error, :unavailable} = SecureStore.delete(:credential, InvalidAdapter)
    assert {:error, :unavailable} = SecureStore.fetch(:credential, FailingAdapter)
    assert {:error, :unavailable} = SecureStore.put(:credential, "value", FailingAdapter)
    assert {:error, :unavailable} = SecureStore.delete(:credential, FailingAdapter)
    assert {:error, :unavailable} = SecureStore.fetch(:credential, __MODULE__.Missing)
  end

  test "ships an iOS-only device-bound Keychain manifest without a file fallback" do
    manifest_path = Application.app_dir(:wotex_mobile_secure_store, "priv/mob_plugin.exs")
    {manifest, _} = Code.eval_file(manifest_path)

    assert manifest.name == :wotex_mobile_secure_store
    assert manifest.plugin_spec_version == 1
    assert manifest.ios.frameworks == ["Security"]

    assert [%{module: :wotex_secure_store_nif, lang: :objc, platform: :ios}] =
             Enum.map(manifest.nifs, &Map.take(&1, [:module, :lang, :platform]))

    native =
      :wotex_mobile_secure_store
      |> Application.app_dir("priv/native/ios/wotex_secure_store_nif.m")
      |> File.read!()

    assert native =~ "kSecClassGenericPassword"
    assert native =~ "kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly"
    assert native =~ "kSecAttrSynchronizable : @NO"
    assert native =~ "ERL_NIF_DIRTY_JOB_IO_BOUND"
    refute native =~ "NSUserDefaults"
    refute native =~ "writeToFile"
  end

  test "fails explicitly when the native plugin is absent on a development host" do
    assert {:error, :unavailable} = SecureStore.fetch(:credential)
    assert {:error, :unavailable} = SecureStore.put(:credential, "value")
    assert {:error, :unavailable} = SecureStore.delete(:credential)
  end
end
