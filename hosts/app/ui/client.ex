defmodule Wotex.Tracker.Host.Browser.Client do
  @moduledoc """
  Connects the standalone browser to its current service instance.

  Ordinary actions delegate to `Wotex.Tracker.UI.Local` and the public service
  facade. Operational history is a separate bounded collector read, allowed
  only under an administrator grant checked before and after the fetch. The
  adapter normalizes failures to coded public errors and retains no privileged
  store handle in a LiveView.
  """

  @behaviour Wotex.Tracker.UI.Client
  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.{OperationalHistory, Result}
  alias Wotex.Tracker.Service.HTTP.Server
  alias Wotex.Tracker.UI.Local

  @impl true
  def request({service_provider, server_provider}, token, scope, :operational_history, args, now) do
    result =
      with %{"event" => event, "cursor" => cursor} when map_size(args) == 2 <- args,
           {:ok, service} <- service_provider.(),
           {:ok, _} <- Service.authorize(service, token, scope, "admin", now),
           {:ok, server} <- server_provider.(),
           {:ok, collector} <- Server.child(server, :operational_history),
           {:ok, page} <-
             OperationalHistory.page(collector, event: event, cursor: cursor, limit: 25),
           {:ok, _} <- Service.authorize(service, token, scope, "admin", now) do
        {:ok, page}
      else
        %{} -> {:error, :invalid_request}
        {:error, reason} -> {:error, reason}
        _ -> {:error, :storage_unavailable}
      end

    normalize(result)
  rescue
    _ -> Result.error(:storage_unavailable)
  catch
    :exit, _ -> Result.error(:storage_unavailable)
  end

  def request({service_provider, _}, token, scope, action, args, now),
    do: Local.request(service_provider, token, scope, action, args, now)

  defp normalize({:ok, page}), do: {:ok, page}

  defp normalize({:error, reason})
       when reason in ~w(unauthorized forbidden invalid_request invalid_query invalid_cursor cursor_expired storage_unavailable unavailable)a,
       do: Result.error(reason)

  defp normalize(_), do: Result.error(:storage_unavailable)
end
