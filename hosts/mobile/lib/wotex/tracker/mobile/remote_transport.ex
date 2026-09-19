defmodule Wotex.Tracker.Mobile.RemoteTransport do
  @moduledoc """
  Adds one explicit OS-DNS admission step to the shared bounded HTTP transport.

  The configured HTTPS authority still comes from `Wotex.Tracker.UI.Remote`.
  Resolution cannot change its scheme, host, port, method, path or request.
  """

  @behaviour Wotex.Tracker.UI.RemoteTransport

  @impl true
  def request(
        %{resolver: {resolver, resolver_context}, transport: {transport, transport_context}},
        %{host: host} = authority,
        request
      )
      when is_atom(resolver) and is_atom(transport) and is_binary(host) do
    case resolve(resolver, resolver_context, host) do
      :ok -> transport.request(transport_context, authority, request)
      _error -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  def request(_, _, _), do: {:error, :unavailable}

  defp resolve(resolver, context, host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, _} ->
        :ok

      {:error, :einval} ->
        if Code.ensure_loaded?(resolver) and function_exported?(resolver, :resolve, 2),
          do: resolver.resolve(context, host),
          else: {:error, :resolver_unavailable}
    end
  end
end
