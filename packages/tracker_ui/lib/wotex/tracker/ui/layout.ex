defmodule Wotex.Tracker.UI.Layout do
  @moduledoc """
  Renders the shared browser document for server and kiosk hosts.

  The root layout includes navigation, sign-out, a skip link, connection
  status, and the CSRF token. It loads Phoenix, LiveView, and Tracker assets
  from the local host. Screen content is supplied through `root/1` rather than
  duplicated by each presentation host.
  """

  use Phoenix.Component

  @doc "Renders the common root document for browsers, kiosks and presentation hosts."
  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>WoTEx Tracker</title>
        <link rel="stylesheet" href="/assets/tracker.css" />
        <script defer src="/assets/phoenix/phoenix.min.js">
        </script>
        <script defer src="/assets/liveview/phoenix_live_view.min.js">
        </script>
        <script defer src="/assets/tracker.js">
        </script>
      </head>
      <body>
        <a class="skip" href="#main">Skip to content</a>
        <header class="topbar">
          <a class="brand" href="/">WoTEx <span>Tracker</span></a>
          <nav aria-label="Main navigation">
            <a href="/">Assets</a><a href="/setup">Setup</a><a href="/dashboards">Dashboards</a><a href="/access">Access</a>
            <.form for={%{}} action="/session/logout" method="post">
              <button class="text-button" type="submit">Sign out</button>
            </.form>
          </nav>
        </header>
        <div id="connection-status" role="status" aria-live="polite" hidden>
          Reconnecting. Displayed information may be out of date.
        </div>
        <noscript>This application needs JavaScript for its interactive screens.</noscript>
        {@inner_content}
      </body>
    </html>
    """
  end
end
