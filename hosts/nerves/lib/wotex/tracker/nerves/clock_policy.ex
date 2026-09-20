defmodule Wotex.Tracker.Nerves.ClockPolicy do
  @moduledoc """
  Keeps time-sensitive network operations closed until this boot has confirmed
  NTP synchronization.

  Loopback service remains available with the host's explicit last-known clock
  estimate when no provider-token delivery is configured. Direct TLS exposure
  and APNs provider JWT creation require a positive synchronization result from
  the current runtime; an exception, exit or malformed result fails closed.
  """

  @doc "Requires synchronized time for direct TLS or a configured APNs provider."
  @spec admit(keyword(), boolean(), (-> term())) :: :ok | {:error, atom()}
  def admit(options, provider_token?, synchronized?)
      when is_list(options) and is_boolean(provider_token?) and is_function(synchronized?, 0) do
    case {options[:exposure], provider_token?} do
      {:loopback, false} -> :ok
      {:loopback, true} -> require_synchronized(synchronized?)
      {:tls, _} -> require_synchronized(synchronized?)
      _ -> {:error, :invalid_configuration}
    end
  end

  def admit(_, _, _), do: {:error, :invalid_configuration}

  defp require_synchronized(synchronized?) do
    if synchronized?.(), do: :ok, else: {:error, :clock_unsynchronized}
  rescue
    _ -> {:error, :clock_unsynchronized}
  catch
    _, _ -> {:error, :clock_unsynchronized}
  end
end
