defmodule Wotex.Tracker.UI.SessionController do
  @moduledoc false
  use Phoenix.Controller, formats: [:html]
  import Plug.Conn
  alias Wotex.Tracker.UI.Sessions

  def new(conn, _), do: render(conn, :new, message: nil)

  def create(conn, params) do
    sessions = Phoenix.Controller.endpoint_module(conn).config(:tracker_ui)[:sessions]
    Sessions.logout(sessions, get_session(conn, :browser_session))
    conn = conn |> clear_session() |> configure_session(renew: true)

    case Sessions.login(sessions, params["token"], params["scope"]) do
      {:ok, %{"id" => id}} ->
        conn |> put_session(:browser_session, id) |> redirect(to: "/")

      {:error, _} ->
        conn
        |> put_status(:unauthorized)
        |> render(:new,
          message: "Sign-in failed. Check your scope and credential, or contact the operator."
        )
    end
  end

  def delete(conn, _) do
    sessions = Phoenix.Controller.endpoint_module(conn).config(:tracker_ui)[:sessions]
    Sessions.logout(sessions, get_session(conn, :browser_session))
    conn |> clear_session() |> configure_session(drop: true) |> redirect(to: "/sign-in")
  end
end
