defmodule Wotex.Tracker.UI.TestClient do
  @moduledoc false
  @behaviour Wotex.Tracker.UI.Client
  alias Wotex.Tracker.UI.Local

  @impl true
  def request({provider, faults}, token, scope, action, args, now) do
    fault =
      Agent.get_and_update(faults, fn current ->
        value = Map.get(current, action)
        next = if match?({:page, _}, value), do: current, else: Map.delete(current, action)
        {value, next}
      end)

    respond(fault, provider, token, scope, action, args, now)
  end

  defp respond({:page, page}, provider, token, scope, :operational_history, _, now) do
    case Local.request(provider, token, scope, :authorize, %{}, now) do
      {:ok, %{"can_manage_queries" => true}} -> {:ok, page}
      {:ok, _} -> {:error, %{"code" => "forbidden"}}
      error -> error
    end
  end

  defp respond(fault, provider, token, scope, action, args, now) do
    case fault do
      :unavailable ->
        {:error, %{"code" => "storage_unavailable"}}

      {:deny, code} when code in ~w(forbidden unauthorized) ->
        {:error, %{"code" => code}}

      :lost_reply ->
        {:ok, _} = Local.request(provider, token, scope, action, args, now)
        {:ok, %{"outcome" => "unknown", "operation_id" => args["operation"]}}

      nil ->
        Local.request(provider, token, scope, action, args, now)
    end
  end
end
