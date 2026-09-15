defmodule Wotex.Tracker.Service.PeerCredentials do
  @moduledoc false
  @behaviour Wotex.Runtime.Credentials
  @impl true
  def resolve(%{names: ["bearer"]}, _form, _context, table) do
    [{:token, token}] = :ets.lookup(table, :token)
    {:ok, token}
  end
end
