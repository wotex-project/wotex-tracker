defmodule Wotex.Tracker.UI.PromptPeer do
  @moduledoc false

  def propose(agent, request) do
    Agent.get_and_update(agent, fn state ->
      {state.response, %{state | calls: [request | state.calls]}}
    end)
  end
end
