defmodule Wotex.Tracker.Mobile.Endpoint do
  @moduledoc false

  use Phoenix.Endpoint, otp_app: :wotex_tracker_mobile

  @session [
    store: :cookie,
    key: "_wotex_tracker_mobile",
    signing_salt: "tracker-mobile-sign-v1",
    encryption_salt: "tracker-mobile-encrypt-v1",
    same_site: "Strict",
    http_only: true,
    secure: false,
    max_age: 3_600
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session]],
    longpoll: false
  )

  plug(:browser_session)
  plug(Wotex.Tracker.Mobile.SessionGate)
  plug(Plug.Static, at: "/assets", from: :wotex_tracker_ui, only: ~w(tracker.css tracker.js))

  plug(Plug.Static,
    at: "/assets/phoenix",
    from: {:phoenix, "priv/static"},
    only: ~w(phoenix.min.js)
  )

  plug(Plug.Static,
    at: "/assets/liveview",
    from: {:phoenix_live_view, "priv/static"},
    only: ~w(phoenix_live_view.min.js)
  )

  plug(Plug.Parsers, parsers: [:urlencoded], pass: [], length: 8_192)
  plug(Wotex.Tracker.UI.Router)

  defp browser_session(conn, _) do
    Plug.Session.call(conn, Plug.Session.init(@session))
  end
end
