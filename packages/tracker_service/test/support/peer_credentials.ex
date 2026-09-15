defmodule Wotex.Tracker.Service.PeerCredentials do
  @moduledoc false
  use GenServer
  @behaviour Wotex.Runtime.Credentials

  def start_link(token), do: GenServer.start_link(__MODULE__, token)

  @impl true
  def init(token), do: {:ok, token}

  @impl true
  def handle_call(:resolve, _, token), do: {:reply, {:ok, token}, token}

  @impl true
  def format_status(status), do: Map.put(status, :state, :redacted)

  @impl Wotex.Runtime.Credentials
  def resolve(%{names: ["bearer"]}, _, _, vault) when is_pid(vault),
    do: GenServer.call(vault, :resolve)

  def resolve(%{names: ["bearer"]}, _form, _context, table) do
    [{:token, token}] = :ets.lookup(table, :token)
    {:ok, token}
  end
end
