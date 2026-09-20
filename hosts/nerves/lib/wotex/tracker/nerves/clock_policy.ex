defmodule Wotex.Tracker.Nerves.ClockPolicy do
  @moduledoc """
  Keeps network exposure closed until this boot has confirmed NTP synchronization.

  Loopback service remains available with the host's explicit last-known clock
  estimate. Direct TLS exposure requires a positive synchronization result from
  the current runtime; an exception, exit or malformed result fails closed.
  """

  @doc "Admits loopback offline, but requires synchronized time for direct TLS."
  @spec admit(keyword(), (-> term())) :: :ok | {:error, atom()}
  def admit(options, synchronized?) when is_list(options) and is_function(synchronized?, 0) do
    case options[:exposure] do
      :loopback -> :ok
      :tls -> require_synchronized(synchronized?)
      _ -> {:error, :invalid_configuration}
    end
  end

  def admit(_, _), do: {:error, :invalid_configuration}

  defp require_synchronized(synchronized?) do
    if synchronized?.(), do: :ok, else: {:error, :clock_unsynchronized}
  rescue
    _ -> {:error, :clock_unsynchronized}
  catch
    _, _ -> {:error, :clock_unsynchronized}
  end
end
