defmodule Wotex.Tracker.UI.Local do
  @moduledoc """
  Local presentation adapter using only the authorized public service facade.

  The host supplies a zero-argument provider returning `{:ok, service}`. Resolve
  the current service on every call so a restarted store is never cached in a
  LiveView. No request selects a module, function, clock or privileged store API.
  """
  @behaviour Wotex.Tracker.UI.Client
  alias Wotex.Tracker.Service

  @impl true
  def request(provider, token, scope, action, arguments, now) do
    case provider.() do
      {:ok, service} -> dispatch(service, token, scope, action, arguments, now)
      _ -> {:error, %{"code" => "storage_unavailable"}}
    end
  catch
    :exit, _ -> {:error, %{"code" => "storage_unavailable"}}
  end

  defp dispatch(service, token, scope, :authorize, _, now) do
    case Service.authorize(service, token, scope, "read", now) do
      {:ok, _} ->
        {:ok,
         %{
           "scope" => scope,
           "can_enroll" =>
             match?({:ok, _}, Service.authorize(service, token, scope, "enroll", now)),
           "can_ingest" =>
             match?({:ok, _}, Service.authorize(service, token, scope, "ingest", now)),
           "can_manage_queries" =>
             match?({:ok, _}, Service.authorize(service, token, scope, "admin", now))
         }}

      {:error, reason} ->
        {:error, %{"code" => Atom.to_string(reason)}}
    end
  end

  defp dispatch(service, token, scope, :list, args, now),
    do: Service.list(service, token, scope, args["resource"], args["params"] || %{}, now)

  defp dispatch(service, token, scope, :get, args, now),
    do: Service.get(service, token, scope, args["resource"], args["id"], now)

  defp dispatch(service, token, scope, :history, args, now),
    do:
      Service.history(
        service,
        token,
        scope,
        args["resource"],
        args["id"],
        args["params"] || %{},
        now
      )

  defp dispatch(service, token, scope, :analytics, args, now),
    do: Service.analytics(service, token, scope, args["query"], now)

  defp dispatch(service, token, scope, :execute_saved_query, args, now),
    do: Service.execute_saved_query(service, token, scope, args["id"], now)

  defp dispatch(service, token, scope, :save_query, args, now),
    do: Service.save_query(service, token, scope, args["operation"], args["request"], now)

  defp dispatch(service, token, scope, :delete_query, args, now),
    do: Service.delete_query(service, token, scope, args["operation"], args["request"], now)

  defp dispatch(service, token, scope, :enroll, args, now),
    do: Service.enroll(service, token, scope, args["operation"], args["request"], now)

  defp dispatch(service, token, scope, :associate, args, now),
    do: Service.associate(service, token, scope, args["operation"], args["request"], now)

  defp dispatch(service, token, scope, :materialize, args, now),
    do: Service.materialize(service, token, scope, args["operation"], args["request"], now)

  defp dispatch(service, token, scope, :operation, args, now),
    do: Service.operation(service, token, scope, args["id"], now)

  defp dispatch(service, token, scope, :submit, args, now),
    do: Service.submit(service, token, scope, args["operation"], args["request"], now)

  defp dispatch(_, _, _, _, _, _), do: {:error, %{"code" => "unsupported"}}
end
