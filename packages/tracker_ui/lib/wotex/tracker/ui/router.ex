defmodule Wotex.Tracker.UI.Router do
  @moduledoc "Browser routes mounted by an explicitly configured host endpoint."
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {Wotex.Tracker.UI.Layout, :root})
    plug(:protect_from_forgery)

    plug(:put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
      "referrer-policy" => "no-referrer"
    })

    plug(:no_cache)
  end

  scope "/", Wotex.Tracker.UI, log: false do
    pipe_through(:browser)
    get("/sign-in", SessionController, :new, log: false)
    post("/session", SessionController, :create, log: false)
    post("/session/logout", SessionController, :delete, log: false)

    live_session :tracker, on_mount: [{Wotex.Tracker.UI.Auth, :default}] do
      live("/", BrowseLive, :assets)
      live("/setup", BrowseLive, :observations)
      live("/dashboards", DashboardIndexLive, :index)
      live("/dashboards/:id", DashboardLive, :show)
      live("/observations/:id", ObservationLive, :show)
      live("/assets/:id/observations", AssociationSelectLive, :index)
      live("/assets/:thing_id/observations/:observation_id", AssociationLive, :show)
      live("/assets/:id/analytics", AnalyticsLive, :show)
      live("/assets/:id", AssetLive, :show)
    end
  end

  defp no_cache(conn, _), do: Plug.Conn.put_resp_header(conn, "cache-control", "no-store")
end
