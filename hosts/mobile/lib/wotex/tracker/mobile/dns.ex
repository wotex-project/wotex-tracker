defmodule Wotex.Tracker.Mobile.DNS do
  @moduledoc """
  Resolves the configured remote service through the mobile OS resolver.

  Mob's NIF is absent on ordinary development hosts, where BEAM DNS remains
  available. Device resolver failures stay explicit and never select another
  host.
  """

  @doc "Seeds the configured hostname for the following Mint request."
  @spec resolve(term(), String.t()) :: :ok | {:error, atom() | tuple()}
  def resolve(context, host) when is_binary(host) do
    resolver = if is_atom(context) and not is_nil(context), do: context, else: Mob.DNS

    case resolver.resolve(host) do
      {:ok, {_, _, _, _}} -> :ok
      {:error, :nif_not_loaded} -> :ok
      {:error, reason} -> {:error, reason}
      unexpected when not is_tuple(unexpected) -> {:error, :resolver_unavailable}
    end
  rescue
    _ -> {:error, :resolver_unavailable}
  catch
    _, _ -> {:error, :resolver_unavailable}
  end
end
