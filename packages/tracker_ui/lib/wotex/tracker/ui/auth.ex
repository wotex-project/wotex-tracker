defmodule Wotex.Tracker.UI.Auth do
  @moduledoc """
  Rechecks service authority for protected LiveViews.

  The mount hook reads only an opaque browser session ID from the LiveView
  session. `request/3` asks `Wotex.Tracker.UI.Sessions` to use the server-held
  credential. Authority is checked on mount, before each user event, and on a
  five-second idle timer; a failed check redirects to sign-in.
  """

  import Phoenix.Component
  import Phoenix.LiveView
  alias Wotex.Tracker.UI.Sessions

  @doc false
  def on_mount(:default, _, session, socket) do
    sessions = socket.endpoint.config(:tracker_ui)[:sessions]
    socket = assign(socket, sessions: sessions, session_id: session["browser_session"])

    case authorize(socket) do
      {:ok, socket} ->
        if connected?(socket), do: Process.send_after(self(), :check_authority, 5000)

        {:cont,
         socket
         |> attach_hook(:authority, :handle_event, fn _, _, socket ->
           case authorize(socket) do
             {:ok, socket} -> {:cont, socket}
             {:error, socket} -> {:halt, socket}
           end
         end)
         |> attach_hook(:idle_authority, :handle_info, fn
           :check_authority, socket ->
             case authorize(socket) do
               {:ok, socket} ->
                 Process.send_after(self(), :check_authority, 5000)
                 {:halt, socket}

               {:error, socket} ->
                 {:halt, socket}
             end

           _, socket ->
             {:cont, socket}
         end)}

      {:error, socket} ->
        {:halt, socket}
    end
  end

  @doc "Calls the configured service using the server-held browser credential."
  def request(socket, action, arguments \\ %{}),
    do: Sessions.request(socket.assigns.sessions, socket.assigns.session_id, action, arguments)

  defp authorize(socket) do
    case request(socket, :authorize) do
      {:ok, identity} -> {:ok, assign(socket, identity: identity)}
      {:error, _} -> {:error, redirect(socket, to: "/sign-in")}
    end
  end
end
