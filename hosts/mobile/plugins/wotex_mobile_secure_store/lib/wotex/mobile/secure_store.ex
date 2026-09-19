defmodule Wotex.Mobile.SecureStore do
  @moduledoc """
  Closed access to the mobile host's device-only secure-storage slots.

  The implementation deliberately has no file or preference fallback. A host
  without the statically linked native plugin reports `:unavailable`.
  """

  @keys [:credential, :installation_id]
  @maximum_value_bytes 4_096
  @native :wotex_secure_store_nif

  @type key :: :credential | :installation_id
  @type error :: {:error, :invalid_data | :not_found | :unavailable}

  @doc "Reads one closed secure-storage slot."
  @spec fetch(key(), module()) :: {:ok, binary()} | error()
  def fetch(key, adapter \\ @native)

  def fetch(key, adapter) when key in @keys and is_atom(adapter) do
    case invoke(adapter, :fetch, [Atom.to_string(key)]) do
      {:ok, value}
      when is_binary(value) and byte_size(value) in 1..@maximum_value_bytes ->
        {:ok, value}

      {:error, :not_found} ->
        {:error, :not_found}

      _ ->
        {:error, :unavailable}
    end
  end

  def fetch(_, _), do: {:error, :invalid_data}

  @doc "Replaces one closed secure-storage slot."
  @spec put(key(), binary(), module()) :: :ok | error()
  def put(key, value, adapter \\ @native)

  def put(key, value, adapter)
      when key in @keys and is_binary(value) and
             byte_size(value) in 1..@maximum_value_bytes and is_atom(adapter) do
    case invoke(adapter, :put, [Atom.to_string(key), value]) do
      :ok -> :ok
      _ -> {:error, :unavailable}
    end
  end

  def put(_, _, _), do: {:error, :invalid_data}

  @doc "Deletes one closed secure-storage slot; deletion is idempotent."
  @spec delete(key(), module()) :: :ok | error()
  def delete(key, adapter \\ @native)

  def delete(key, adapter) when key in @keys and is_atom(adapter) do
    case invoke(adapter, :delete, [Atom.to_string(key)]) do
      :ok -> :ok
      _ -> {:error, :unavailable}
    end
  end

  def delete(_, _), do: {:error, :invalid_data}

  defp invoke(adapter, function, arguments) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, function, length(arguments)),
      do: apply(adapter, function, arguments),
      else: {:error, :unavailable}
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end
end
