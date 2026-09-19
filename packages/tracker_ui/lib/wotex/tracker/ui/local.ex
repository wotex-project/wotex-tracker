defmodule Wotex.Tracker.UI.Local do
  @moduledoc """
  Local presentation adapter using only the authorized public service facade.

  The host supplies a zero-argument provider returning `{:ok, service}`. Resolve
  the current service on every call so a restarted store is never cached in a
  LiveView. No request selects a module, function, clock or privileged store API.
  """

  @behaviour Wotex.Tracker.UI.Client
  alias Wotex.Runtime.Context
  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.Identifier

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
    case Service.access(service, token, scope, now) do
      {:ok, %{"permissions" => permissions}} ->
        {:ok,
         %{
           "scope" => scope,
           "can_enroll" => "enroll" in permissions,
           "can_ingest" => "ingest" in permissions,
           "can_read_raw" => "raw" in permissions,
           "can_manage_queries" => "admin" in permissions
         }}

      {:error, %{"code" => _} = error} ->
        {:error, error}
    end
  end

  defp dispatch(service, token, scope, :session_context, _, now) do
    case Service.access(service, token, scope, now) do
      {:ok, access} -> {:ok, session_context(access, scope)}
      {:error, %{"code" => _} = error} -> {:error, error}
    end
  end

  defp dispatch(service, token, scope, :access, _, now) do
    case Service.access(service, token, scope, now) do
      {:ok, access} ->
        {:ok,
         %{
           "principal" => access["principal"],
           "scope" => access["scope"],
           "expires_at" => access["expires_at"]
         }}

      {:error, %{"code" => _} = error} ->
        {:error, error}
    end
  end

  defp dispatch(service, token, scope, :revocation_context, _, now) do
    with {:ok, %{"permissions" => permissions} = access} <-
           Service.access(service, token, scope, now),
         true <- "admin" in permissions,
         {:ok, %{"generation" => generation}} <-
           Service.list(service, token, scope, "enrollments", %{"limit" => 1}, now) do
      {:ok, %{"credential_id" => access["credential_id"], "expected_generation" => generation}}
    else
      false ->
        {:error, %{"code" => "forbidden"}}

      {:error, %{"code" => _} = error} ->
        {:error, error}

      _ ->
        {:error, %{"code" => "storage_unavailable"}}
    end
  end

  defp dispatch(service, token, scope, :events, args, now),
    do: Service.events(service, token, scope, args["cursor"], now)

  defp dispatch(service, token, scope, :operations, args, now),
    do: Service.operations(service, token, scope, args["params"] || %{}, now)

  defp dispatch(service, token, scope, :credentials, _, now),
    do: Service.credentials(service, token, scope, now)

  defp dispatch(service, token, scope, :list, args, now),
    do: Service.list(service, token, scope, args["resource"], args["params"] || %{}, now)

  defp dispatch(service, token, scope, :get, args, now),
    do: Service.get(service, token, scope, args["resource"], args["id"], now)

  defp dispatch(service, token, scope, :arming, args, now),
    do: Service.get(service, token, scope, "arming", args["id"], now)

  defp dispatch(service, token, scope, :owner_presence, args, now),
    do: Service.get(service, token, scope, "owner_presence", args["id"], now)

  defp dispatch(service, token, scope, :thing_policies, args, now),
    do: Service.thing_policies(service, token, scope, args["thing"], now)

  defp dispatch(service, token, scope, :thing_rules, args, now),
    do: Service.thing_rules(service, token, scope, args["thing"], now)

  defp dispatch(service, token, scope, :thing_alerts, args, now),
    do: Service.thing_alerts(service, token, scope, args["thing"], args["params"] || %{}, now)

  defp dispatch(service, token, scope, :thing_trips, args, now),
    do: Service.thing_trips(service, token, scope, args["thing"], args["params"] || %{}, now)

  defp dispatch(service, token, scope, :trip_summary, args, now),
    do: Service.trip_summary(service, token, scope, args["thing"], args["trip"], now)

  defp dispatch(service, token, scope, :read_property, args, now) do
    {:ok, context} =
      Context.new(
        request_id: Identifier.uuid(),
        deadline: System.monotonic_time(:millisecond) + 5000
      )

    Service.read_property(service, token, scope, args["thing"], args["name"], context, now)
  end

  defp dispatch(service, token, scope, :raw_observation, args, now),
    do: Service.raw_observation(service, token, scope, args["id"], now)

  defp dispatch(service, token, scope, :raw_evidence, args, now),
    do: Service.raw_evidence(service, token, scope, args["id"], now)

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

  defp dispatch(service, token, scope, :route_history, args, now),
    do: Service.route_history(service, token, scope, args["request"], now)

  defp dispatch(service, token, scope, :execute_saved_query, args, now),
    do: Service.execute_saved_query(service, token, scope, args["id"], now)

  defp dispatch(service, token, scope, :save_query, args, now),
    do: Service.save_query(service, token, scope, args["operation"], args["request"], now)

  defp dispatch(service, token, scope, :delete_query, args, now),
    do: Service.delete_query(service, token, scope, args["operation"], args["request"], now)

  defp dispatch(service, token, scope, :save_policy, args, now),
    do: Service.save_policy(service, token, scope, args["operation"], args["request"], now)

  defp dispatch(service, token, scope, :delete_policy, args, now),
    do: Service.delete_policy(service, token, scope, args["operation"], args["request"], now)

  defp dispatch(service, token, scope, :acknowledge_alert, args, now),
    do: Service.acknowledge_alert(service, token, scope, args["operation"], args["request"], now)

  defp dispatch(service, token, scope, :set_arming, args, now),
    do: Service.set_arming(service, token, scope, args["operation"], args["request"], now)

  defp dispatch(service, token, scope, :enroll, args, now),
    do: Service.enroll(service, token, scope, args["operation"], args["request"], now)

  defp dispatch(service, token, scope, :associate, args, now),
    do: Service.associate(service, token, scope, args["operation"], args["request"], now)

  defp dispatch(service, token, scope, :materialize, args, now),
    do: Service.materialize(service, token, scope, args["operation"], args["request"], now)

  defp dispatch(service, token, scope, :unenroll, args, now),
    do: Service.unenroll(service, token, scope, args["operation"], args["request"], now)

  defp dispatch(service, token, scope, :revoke, args, now),
    do: Service.revoke(service, token, scope, args["operation"], args["request"], now)

  defp dispatch(service, token, scope, :operation, args, now),
    do: Service.operation(service, token, scope, args["id"], now)

  defp dispatch(service, token, scope, :submit, args, now),
    do: Service.submit(service, token, scope, args["operation"], args["request"], now)

  defp dispatch(_, _, _, _, _, _), do: {:error, %{"code" => "unsupported"}}

  defp session_context(access, scope) do
    permissions = access["permissions"]

    %{
      "identity" => %{
        "scope" => scope,
        "can_enroll" => "enroll" in permissions,
        "can_ingest" => "ingest" in permissions,
        "can_read_raw" => "raw" in permissions,
        "can_manage_queries" => "admin" in permissions
      },
      "access" => %{
        "credential_id" => access["credential_id"],
        "principal" => access["principal"],
        "scope" => access["scope"],
        "expires_at" => access["expires_at"]
      }
    }
  end
end
