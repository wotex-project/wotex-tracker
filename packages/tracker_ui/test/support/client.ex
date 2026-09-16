defmodule Wotex.Tracker.UI.TestClient do
  @moduledoc false
  @behaviour Wotex.Tracker.UI.Client
  alias Wotex.Tracker.UI.Local

  @impl true
  def request({provider, faults}, token, scope, action, args, now) do
    fault = Agent.get_and_update(faults, &{Map.get(&1, action), Map.delete(&1, action)})

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
