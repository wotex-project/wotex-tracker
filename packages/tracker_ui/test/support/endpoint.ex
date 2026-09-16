defmodule Wotex.Tracker.UI.TestEndpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :wotex_tracker_ui

  @session [
    store: :cookie,
    key: "_tracker_ui_test",
    signing_salt: "browser-sign",
    encryption_salt: "browser-encrypt",
    same_site: "Strict",
    http_only: true,
    secure: true,
    max_age: 3600
  ]
  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session]],
    longpoll: false
  )

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

  plug(Plug.Parsers, parsers: [:urlencoded], pass: [], length: 8192)
  plug(Plug.Session, @session)
  plug(Wotex.Tracker.UI.Router)
end
