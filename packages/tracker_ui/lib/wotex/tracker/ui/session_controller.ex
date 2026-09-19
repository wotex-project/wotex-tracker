defmodule Wotex.Tracker.UI.SessionController do
  @moduledoc false

  use Phoenix.Controller, formats: [:html]
  import Plug.Conn
  alias Wotex.Tracker.UI.{SessionGuard, Sessions}

  def new(conn, _) do
    flash = conn.assigns[:flash] || %{}

    render(conn, :new,
      message: Phoenix.Flash.get(flash, :error) || Phoenix.Flash.get(flash, :info)
    )
  end

  def create(conn, params) do
    tracker_ui = Phoenix.Controller.endpoint_module(conn).config(:tracker_ui)
    sessions = tracker_ui[:sessions]
    retained = SessionGuard.retain(tracker_ui[:session_guard], get_session(conn))

    case Sessions.logout(sessions, get_session(conn, :browser_session)) do
      :ok ->
        conn =
          conn |> clear_session() |> configure_session(renew: true) |> retain_session(retained)

        case Sessions.login(sessions, params["token"], params["scope"]) do
          {:ok, %{"id" => id}} ->
            conn |> put_session(:browser_session, id) |> redirect(to: "/")

          {:error, _} ->
            sign_in_failed(conn)
        end

      {:error, _} ->
        conn
        |> put_status(:service_unavailable)
        |> render(:new,
          message: "Your existing session could not be ended. Retry when storage is available."
        )
    end
  end

  def delete(conn, _) do
    tracker_ui = Phoenix.Controller.endpoint_module(conn).config(:tracker_ui)
    sessions = tracker_ui[:sessions]
    retained = SessionGuard.retain(tracker_ui[:session_guard], get_session(conn))

    case Sessions.logout(sessions, get_session(conn, :browser_session)) do
      :ok ->
        conn
        |> clear_session()
        |> configure_session(if(retained == %{}, do: [drop: true], else: [renew: true]))
        |> retain_session(retained)
        |> redirect(to: "/sign-in")

      {:error, _} ->
        conn
        |> put_flash(:error, "Sign-out could not complete. Your session remains active.")
        |> redirect(to: "/")
    end
  end

  defp sign_in_failed(conn) do
    conn
    |> put_status(:unauthorized)
    |> render(:new,
      message: "Sign-in failed. Check your scope and credential, or contact the operator."
    )
  end

  defp retain_session(conn, retained) do
    Enum.reduce(retained, conn, fn {key, value}, current -> put_session(current, key, value) end)
  end
end
