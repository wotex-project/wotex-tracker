defmodule Wotex.Tracker.Mobile.Runtime do
  @moduledoc false

  use GenServer
  alias Wotex.Tracker.Mobile.WebSession

  def start_link(%WebSession{} = session),
    do: GenServer.start_link(__MODULE__, session, name: __MODULE__)

  def web_session, do: GenServer.call(__MODULE__, :web_session)

  @impl true
  def init(session), do: {:ok, session}

  @impl true
  def handle_call(:web_session, _from, session), do: {:reply, session, session}
end
