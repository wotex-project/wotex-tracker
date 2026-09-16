defmodule Wotex.Tracker.Host.Browser.Endpoint do
  @moduledoc false

  use Phoenix.Endpoint, otp_app: :wotex_tracker_host

  @session [
    store: :cookie,
    key: "_wotex_tracker_browser",
    signing_salt: "tracker-browser-sign-v1",
    encryption_salt: "tracker-browser-encrypt-v1",
    same_site: "Strict",
    http_only: true,
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
  plug(:browser_session)
  plug(Wotex.Tracker.UI.Router)

  defp browser_session(conn, _) do
    options = Keyword.put(@session, :secure, config(:url)[:scheme] == "https")
    Plug.Session.call(conn, Plug.Session.init(options))
  end
end
