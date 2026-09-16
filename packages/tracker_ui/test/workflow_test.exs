defmodule Wotex.Tracker.UI.WorkflowTest do
  @moduledoc false
  use ExUnit.Case, async: false
  import Plug.Conn
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Wotex.Tracker.Service.Fixtures
  alias Phoenix.LiveView.Static
  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.{Codec, Identifier}
  alias Wotex.Tracker.UI.{ErrorHTML, Presenter, Sessions, TestClient, TestEndpoint}
  @endpoint TestEndpoint

  setup do
    c = service()
    faults = start_supervised!({Agent, fn -> %{} end})

    sessions =
      start_supervised!(
        {Sessions,
         client: {TestClient, {fn -> {:ok, c.service} end, faults}}, clock: fn -> c.now end}
      )

    start_supervised!({Phoenix.PubSub, name: Wotex.Tracker.UI.TestPubSub})

    start_supervised!(
      {TestEndpoint,
       secret_key_base: String.duplicate("s", 64),
       live_view: [signing_salt: "live-view-test"],
       pubsub_server: Wotex.Tracker.UI.TestPubSub,
       url: [host: "www.example.com", scheme: "https", port: 443],
       check_origin: ["https://www.example.com"],
       render_errors: [formats: [html: Wotex.Tracker.UI.ErrorHTML], layout: false],
       server: false,
       tracker_ui: [sessions: sessions]}
    )

    {:ok, %{"id" => id}} = Sessions.login(sessions, c.admin, c.scope)
    conn = build_conn() |> init_test_session(%{"browser_session" => id})
    Map.merge(c, %{sessions: sessions, session: id, conn: conn, faults: faults})
  end

  test "enroll, reconnect, provision and inspect the same authorized asset", c do
    {:ok, imported} =
      Service.submit(c.service, c.admin, c.scope, Identifier.uuid(), import_request(), c.now)

    observation = imported["data"]["observation_id"]
    operation = Identifier.uuid()
    path = Presenter.path(:observation, observation) <> "?operation=" <> operation
    {:ok, view, html} = live(c.conn, path)
    assert html =~ "Observation evidence"
    refute html =~ c.admin
    refute html =~ "private-hardware"

    view
    |> form("#enroll", enrollment: %{title: "Workshop sensor", confirmed: "true"})
    |> render_submit()

    assert has_element?(view, "a", "Continue provisioning")
    {:ok, receipt} = Service.operation(c.service, c.admin, c.scope, operation, c.now)
    thing = receipt["data"]["thing_id"]
    {:ok, resumed, _} = live(c.conn, path)
    refute has_element?(resumed, "#enroll")
    assert has_element?(resumed, "a", "Continue provisioning")
    {:ok, assets} = Service.list(c.service, c.admin, c.scope, "enrollments", %{}, c.now)
    assert length(assets["items"]) == 1

    asset_path = Presenter.path(:asset, thing) <> "?operation=" <> Identifier.uuid()
    {:ok, asset, _} = live(c.conn, asset_path)
    assert has_element?(asset, "button", "Provision Thing")
    asset |> element("button", "Provision Thing") |> render_click()
    assert has_element?(asset, ".reading", "24.3")
    assert has_element?(asset, "h2", "Measurement history")
    assert render(asset) =~ "connectivity is unknown"
    refute has_element?(asset, "button", "Provision Thing")
    {:ok, state} = Service.get(c.service, c.admin, c.scope, "state", thing, c.now)
    assert state["value"]["measurements"] != []
  end

  test "associate a later observation and update the same Thing", c do
    {thing, _} = enrolled(c)

    {:ok, _} =
      Service.materialize(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        %{"thing_id" => thing, "expected_generation" => "2"},
        c.now
      )

    <<5, _::16, rest::binary>> = elem(observation().payload, 1)

    {:ok, imported} =
      Service.submit(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        import_request(
          %{
            id: "later",
            observed_at: c.now + 1,
            payload: {:bytes, <<5, 6000::16, rest::binary>>}
          },
          "3"
        ),
        c.now
      )

    later = imported["data"]["observation_id"]

    {:ok, asset, _} =
      live(c.conn, Presenter.path(:asset, thing) <> "?operation=" <> Identifier.uuid())

    assert has_element?(asset, "a", "Associate a later observation")

    {:ok, picker, _} = live(c.conn, Presenter.path(:asset, thing) <> "/observations")
    assert render(picker) =~ Presenter.association_path(thing, later)
    assert has_element?(picker, "a", "Inspect observation")

    assert {:error, {:redirect, %{to: path}}} =
             live(c.conn, Presenter.association_path(thing, later))

    assert path =~ "?operation="
    {:ok, view, _} = live(c.conn, path)
    assert has_element?(view, "h2", "Observation evidence")
    assert has_element?(view, "#associate")

    view
    |> form("#associate", association: %{confirmed: "true"})
    |> render_submit()

    assert has_element?(view, "h2", "Association saved")
    refute has_element?(view, "#associate")
    {:ok, enrollment} = Service.get(c.service, c.admin, c.scope, "enrollments", thing, c.now)
    assert enrollment["value"]["observation_id"] == later
    {:ok, prior_state} = Service.get(c.service, c.admin, c.scope, "state", thing, c.now)
    refute prior_state["value"]["observation_id"] == later

    assert {:error, {:redirect, %{to: asset_path}}} = live(c.conn, Presenter.path(:asset, thing))
    {:ok, update, _} = live(c.conn, asset_path)
    assert has_element?(update, "button", "Update Thing")
    assert render(update) =~ "prior retained measurements"
    update |> element("button", "Update Thing") |> render_click()
    assert render(update) =~ "30.0"
    refute has_element?(update, "button", "Update Thing")
    {:ok, history} = Service.history(c.service, c.admin, c.scope, "state", thing, %{}, c.now)
    assert length(history["items"]) == 2
  end

  test "lost association reply recovers through its receipt without another association", c do
    {thing, _} = enrolled(c)

    {:ok, imported} =
      Service.submit(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        import_request(%{id: "later", observed_at: c.now + 1}, "2"),
        c.now
      )

    later = imported["data"]["observation_id"]
    path = Presenter.association_path(thing, later) <> "?operation=" <> Identifier.uuid()
    {:ok, view, _} = live(c.conn, path)
    Agent.update(c.faults, &Map.put(&1, :associate, :lost_reply))
    view |> form("#associate", association: %{confirmed: "true"}) |> render_submit()
    assert has_element?(view, "h2", "Association outcome unknown")
    refute has_element?(view, "#associate")
    {:ok, resumed, _} = live(c.conn, path)
    assert has_element?(resumed, "h2", "Association saved")

    {:ok, history} =
      Service.history(c.service, c.admin, c.scope, "enrollments", thing, %{}, c.now)

    assert length(history["items"]) == 2

    {:ok, newer} =
      Service.submit(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        import_request(%{id: "newer", observed_at: c.now + 2}, "4"),
        c.now
      )

    {:ok, _} =
      Service.associate(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        %{
          "thing_id" => thing,
          "observation_id" => newer["data"]["observation_id"],
          "owner_confirmed" => true,
          "expected_generation" => "5"
        },
        c.now
      )

    {:ok, historical, _} = live(c.conn, path)
    assert has_element?(historical, "h2", "Association saved")
    assert render(historical) =~ "receipt records an earlier association"
    refute has_element?(historical, "a", "Update Thing")
  end

  test "reader and stale association cannot change an asset", c do
    {thing, _} = enrolled(c)

    {:ok, imported} =
      Service.submit(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        import_request(%{id: "later", observed_at: c.now + 1}, "2"),
        c.now
      )

    later = imported["data"]["observation_id"]
    path = Presenter.association_path(thing, later) <> "?operation=" <> Identifier.uuid()
    {:ok, %{"id" => reader}} = Sessions.login(c.sessions, c.reader, c.scope)
    conn = build_conn() |> init_test_session(%{"browser_session" => reader})

    {:ok, read_asset, _} =
      live(conn, Presenter.path(:asset, thing) <> "?operation=" <> Identifier.uuid())

    refute has_element?(read_asset, "a", "Associate a later observation")
    {:ok, readonly, _} = live(conn, path)
    refute has_element?(readonly, "#associate")
    render_submit(readonly, "associate", %{"association" => %{"confirmed" => "true"}})
    assert render(readonly) =~ "does not permit"

    {:ok, admin, _} = live(c.conn, path)

    {:ok, _} =
      Service.submit(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        import_request(%{id: "newer", observed_at: c.now + 2}, "3"),
        c.now
      )

    admin |> form("#associate", association: %{confirmed: "true"}) |> render_submit()
    assert render(admin) =~ "changed since this page loaded"
    refute has_element?(admin, "#associate")
    {:ok, enrollment} = Service.get(c.service, c.admin, c.scope, "enrollments", thing, c.now)
    refute enrollment["value"]["observation_id"] == later
  end

  test "association picker pages observations and unrelated receipts cannot submit", c do
    {thing, enrollment_operation} = enrolled(c)

    for generation <- 2..26 do
      assert {:ok, _} =
               Service.submit(
                 c.service,
                 c.admin,
                 c.scope,
                 Identifier.uuid(),
                 import_request(
                   %{id: "later-#{generation}", observed_at: c.now + generation},
                   to_string(generation)
                 ),
                 c.now
               )
    end

    {:ok, picker, _} = live(c.conn, Presenter.path(:asset, thing) <> "/observations")
    assert has_element?(picker, "button", "Next page")
    picker |> element("button", "Next page") |> render_click()
    refute has_element?(picker, "button", "Next page")

    {:ok, page} = Service.list(c.service, c.admin, c.scope, "observations", %{}, c.now)
    observation = hd(page["items"])["id"]
    path = Presenter.association_path(thing, observation)
    {:ok, unrelated, _} = live(c.conn, path <> "?operation=" <> enrollment_operation)
    assert render(unrelated) =~ "different workflow"
    refute has_element?(unrelated, "#associate")
    {:ok, invalid, _} = live(c.conn, path <> "?operation=invalid")
    refute has_element?(invalid, "#associate")
  end

  test "unresolved observations and missing assets cannot enter association", c do
    {thing, _} = enrolled(c)

    {:ok, imported} =
      Service.submit(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        import_request(%{id: "unknown", payload: {:bytes, <<>>}}, "2"),
        c.now
      )

    unresolved = imported["data"]["observation_id"]
    path = Presenter.association_path(thing, unresolved) <> "?operation=" <> Identifier.uuid()
    {:ok, view, _} = live(c.conn, path)
    assert render(view) =~ "no supported exact profile"
    refute has_element?(view, "#associate")

    {:ok, missing, _} = live(c.conn, "/assets/missing/observations")
    assert has_element?(missing, "[role=alert]")
    refute has_element?(missing, "a", "Inspect observation")

    {:ok, missing_detail, _} =
      live(
        c.conn,
        Presenter.association_path("missing", unresolved) <> "?operation=" <> Identifier.uuid()
      )

    assert has_element?(missing_detail, "[role=alert]")
    refute has_element?(missing_detail, "#associate")
  end

  test "a failed association-picker refresh retains the last bounded page", c do
    {thing, _} = enrolled(c)
    {:ok, picker, _} = live(c.conn, Presenter.path(:asset, thing) <> "/observations")
    assert has_element?(picker, "a", "Inspect observation")
    Agent.update(c.faults, &Map.put(&1, :list, :unavailable))
    picker |> element("button", "Refresh") |> render_click()
    assert render(picker) =~ "service could not complete"
    assert has_element?(picker, "a", "Inspect observation")
    picker |> element("button", "Refresh") |> render_click()
    refute has_element?(picker, "[role=alert]")
  end

  test "reader cannot enroll even with a forged event", c do
    {:ok, imported} =
      Service.submit(c.service, c.admin, c.scope, Identifier.uuid(), import_request(), c.now)

    {:ok, %{"id" => reader}} = Sessions.login(c.sessions, c.reader, c.scope)
    conn = build_conn() |> init_test_session(%{"browser_session" => reader})

    path =
      Presenter.path(:observation, imported["data"]["observation_id"]) <>
        "?operation=" <> Identifier.uuid()

    {:ok, view, _} = live(conn, path)
    refute has_element?(view, "#enroll")
    render_click(view, "enroll", %{"enrollment" => %{"title" => "Forged", "confirmed" => "true"}})
    assert render(view) =~ "does not permit"
    {:ok, assets} = Service.list(c.service, c.admin, c.scope, "enrollments", %{}, c.now)
    assert assets["items"] == []
  end

  test "stale enrollment writes stay uncommitted until explicitly refreshed", c do
    {:ok, imported} =
      Service.submit(c.service, c.admin, c.scope, Identifier.uuid(), import_request(), c.now)

    path =
      Presenter.path(:observation, imported["data"]["observation_id"]) <>
        "?operation=" <> Identifier.uuid()

    {:ok, view, _} = live(c.conn, path)

    {:ok, _} =
      Service.submit(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        import_request(%{id: "later", observed_at: c.now + 1}, "1"),
        c.now
      )

    view |> form("#enroll", enrollment: %{title: "Stale", confirmed: "true"}) |> render_submit()
    assert render(view) =~ "changed since this page loaded"
    {:ok, assets} = Service.list(c.service, c.admin, c.scope, "enrollments", %{}, c.now)
    assert assets["items"] == []
  end

  test "logout retires an already mounted view", c do
    {:ok, view, _} = live(c.conn, "/")
    Sessions.logout(c.sessions, c.session)
    assert {:error, {:redirect, %{to: "/sign-in"}}} = render_click(view, "refresh")
  end

  test "anonymous mounts and malformed operation references fail closed", c do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(build_conn(), "/")
    {:ok, view, _} = live(c.conn, "/observations/missing?operation=invalid")
    refute has_element?(view, "#enroll")
    assert render(view) =~ "Check the required fields"
  end

  test "sign-in uses CSRF and an encrypted HttpOnly cookie without reflecting a token", c do
    sign_in = get(build_conn(), "/sign-in")
    body = html_response(sign_in, 200)
    assert body =~ "name=\"_csrf_token\""
    assert get_resp_header(sign_in, "cache-control") == ["no-store"]
    assert get_resp_header(sign_in, "content-security-policy") != []

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      build_conn()
      |> put_private(:plug_skip_csrf_protection, false)
      |> post("/session", %{token: c.admin, scope: c.scope})
    end

    logged_in =
      build_conn()
      |> put_private(:plug_skip_csrf_protection, true)
      |> post("/session", %{token: c.admin, scope: c.scope})

    assert redirected_to(logged_in) == "/"
    assert Map.keys(get_session(logged_in)) -- ["_csrf_token", "browser_session"] == []
    refute inspect(logged_in.resp_cookies) =~ c.admin
    cookie = logged_in.resp_cookies["_tracker_ui_test"]
    assert cookie.http_only and cookie.secure and cookie.same_site == "Strict"

    body = logged_in |> recycle() |> get("/") |> html_response(200)
    [_, signed] = Regex.run(~r/data-phx-session="([^"]+)"/, body)
    assert {:ok, %{session: payload}} = Static.verify_token(TestEndpoint, signed)
    assert Map.keys(payload) -- ["_csrf_token", "browser_session"] == []
    refute inspect(payload) =~ c.admin
  end

  test "observation paging is bounded and a failed refresh retains the loaded page", c do
    for generation <- 0..25 do
      assert {:ok, _} =
               Service.submit(
                 c.service,
                 c.admin,
                 c.scope,
                 Identifier.uuid(),
                 import_request(
                   %{id: "observation-#{generation}", observed_at: c.now + generation},
                   to_string(generation)
                 ),
                 c.now
               )
    end

    {:error, {:redirect, %{to: path}}} = live(c.conn, "/setup")
    {:ok, view, _} = live(c.conn, path)

    assert length(
             view
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query(".card")
             |> Enum.to_list()
           ) == 25

    view |> element("button", "Next page") |> render_click()
    refute has_element?(view, "button", "Next page")
    assert has_element?(view, "a", "Inspect observation")
    Agent.update(c.faults, &Map.put(&1, :list, :unavailable))
    view |> element("button", "Refresh") |> render_click()
    assert render(view) =~ "service could not complete"
    assert has_element?(view, "a", "Inspect observation")
    view |> element("button", "Refresh") |> render_click()
    assert has_element?(view, "button", "Next page")
    render_click(view, "unknown-event")
  end

  test "setup imports an observation capture and resumes its durable receipt", c do
    assert {:error, {:redirect, %{to: path}}} = live(c.conn, "/setup")
    assert path =~ "/setup?operation="
    {:ok, view, _} = live(c.conn, path)
    assert has_element?(view, "#import-capture")

    upload_capture(view, Codec.encode!(import_request()["observation"]))
    view |> form("#import-capture") |> render_submit()

    assert has_element?(view, "h2", "Capture imported")
    assert has_element?(view, "a", "Inspect observation")
    refute has_element?(view, "#import-capture")

    {:ok, %{"items" => [row]}} =
      Service.list(c.service, c.admin, c.scope, "observations", %{}, c.now)

    assert has_element?(view, ~s(a[href="/observations/#{row["id"]}"]), "Inspect observation")
    {:ok, resumed, _} = live(c.conn, path)
    assert has_element?(resumed, "h2", "Capture imported")
    refute has_element?(resumed, "#import-capture")
    refute render(resumed) =~ c.admin
    refute render(resumed) =~ "private-hardware"
  end

  test "lost capture import reply is recovered without a duplicate write", c do
    operation = Identifier.uuid()
    path = "/setup?operation=" <> operation
    {:ok, view, _} = live(c.conn, path)
    Agent.update(c.faults, &Map.put(&1, :submit, :lost_reply))

    upload_capture(view, Codec.encode!(import_request()["observation"]))
    view |> form("#import-capture") |> render_submit()

    assert has_element?(view, "h2", "Import outcome unknown")
    refute has_element?(view, "#import-capture")
    view |> element("button", "Check operation outcome") |> render_click()
    assert has_element?(view, "h2", "Capture imported")
    {:ok, resumed, _} = live(c.conn, path)
    assert has_element?(resumed, "h2", "Capture imported")
    {:ok, receipt} = Service.operation(c.service, c.admin, c.scope, operation, c.now)
    assert receipt["outcome"] == "committed"
    {:ok, page} = Service.list(c.service, c.admin, c.scope, "observations", %{}, c.now)
    assert length(page["items"]) == 1
  end

  test "a temporary read failure does not mislabel a committed import as unrelated", c do
    operation = Identifier.uuid()

    {:ok, _} =
      Service.submit(c.service, c.admin, c.scope, operation, import_request(), c.now)

    {:ok, view, _} = live(c.conn, "/setup?operation=" <> operation)
    Agent.update(c.faults, &Map.put(&1, :get, :unavailable))
    view |> element("button", "Check operation outcome") |> render_click()
    assert has_element?(view, "h2", "Import outcome unknown")
    refute render(view) =~ "different workflow"
    view |> element("button", "Check operation outcome") |> render_click()
    assert has_element?(view, "h2", "Capture imported")
  end

  test "invalid captures and reader events do not import observations", c do
    path = "/setup?operation=" <> Identifier.uuid()
    {:ok, view, _} = live(c.conn, path)
    upload_capture(view, ~s({"id":1,"id":2}))
    view |> form("#import-capture") |> render_submit()
    assert render(view) =~ "Check the required fields"
    assert has_element?(view, "#import-capture")

    {:ok, %{"id" => reader}} = Sessions.login(c.sessions, c.reader, c.scope)
    conn = build_conn() |> init_test_session(%{"browser_session" => reader})
    {:ok, readonly, _} = live(conn, path)
    refute has_element?(readonly, "#import-capture")
    render_click(readonly, "import")
    assert render(readonly) =~ "does not permit"
    {:ok, page} = Service.list(c.service, c.admin, c.scope, "observations", %{}, c.now)
    assert page["items"] == []
  end

  test "capture uploads enforce the file bound and a fresh service generation", c do
    {:ok, view, _} = live(c.conn, "/setup?operation=" <> Identifier.uuid())

    oversized =
      file_input(view, "#import-capture", :observation, [
        %{
          name: "large.json",
          content: String.duplicate("x", 262_145),
          type: "application/json"
        }
      ])

    assert {:error, _} = render_upload(oversized, "large.json")
    assert render(view) =~ "Choose one JSON capture of 256 KiB or less"

    {:ok, fresh, _} = live(c.conn, "/setup?operation=" <> Identifier.uuid())

    {:ok, _} =
      Service.submit(c.service, c.admin, c.scope, Identifier.uuid(), import_request(), c.now)

    upload_capture(
      fresh,
      Codec.encode!(import_request(%{id: "later", observed_at: c.now + 1})["observation"])
    )

    fresh |> form("#import-capture") |> render_submit()
    assert render(fresh) =~ "changed since this page loaded"
    refute has_element?(fresh, "h2", "Capture imported")
    {:ok, page} = Service.list(c.service, c.admin, c.scope, "observations", %{}, c.now)
    assert length(page["items"]) == 1
  end

  test "setup rejects an unrelated operation receipt and a malformed reference", c do
    import_operation = Identifier.uuid()

    {:ok, imported} =
      Service.submit(c.service, c.admin, c.scope, Identifier.uuid(), import_request(), c.now)

    observation = imported["data"]["observation_id"]

    {:ok, _} =
      Service.enroll(
        c.service,
        c.admin,
        c.scope,
        import_operation,
        %{
          "observation_id" => observation,
          "title" => "Other workflow",
          "owner_confirmed" => true,
          "expected_generation" => "1"
        },
        c.now
      )

    {:ok, view, _} = live(c.conn, "/setup?operation=" <> import_operation)
    assert render(view) =~ "different workflow"
    refute has_element?(view, "#import-capture")
    {:ok, invalid, _} = live(c.conn, "/setup?operation=invalid")
    refute has_element?(invalid, "#import-capture")
  end

  test "lost enrollment reply is recovered through its receipt after reconnect", c do
    observation = imported(c)
    operation = Identifier.uuid()
    path = Presenter.path(:observation, observation) <> "?operation=" <> operation
    {:ok, view, _} = live(c.conn, path)
    Agent.update(c.faults, &Map.put(&1, :enroll, :lost_reply))

    view
    |> form("#enroll", enrollment: %{title: "Recovered", confirmed: "true"})
    |> render_submit()

    assert has_element?(view, "h2", "Enrollment outcome unknown")
    refute has_element?(view, "#enroll")
    render_click(view, "unknown-event")
    view |> element("button", "Check operation outcome") |> render_click()
    assert has_element?(view, "h2", "Enrollment saved")
    view |> element("button", "Refresh evidence") |> render_click()
    {:ok, resumed, _} = live(c.conn, path)
    assert has_element?(resumed, "h2", "Enrollment saved")
    {:ok, assets} = Service.list(c.service, c.admin, c.scope, "enrollments", %{}, c.now)
    assert length(assets["items"]) == 1
  end

  test "lost provisioning reply and temporary read failures preserve explicit outcomes", c do
    {thing, _} = enrolled(c)
    path = Presenter.path(:asset, thing) <> "?operation=" <> Identifier.uuid()
    {:ok, view, _} = live(c.conn, path)
    Agent.update(c.faults, &Map.put(&1, :materialize, :lost_reply))
    view |> element("button", "Provision Thing") |> render_click()
    assert render(view) =~ "Provisioning outcome: unknown"
    view |> element("button", "Check operation outcome") |> render_click()
    assert render(view) =~ "Provisioning outcome: committed"
    assert has_element?(view, ".reading", "24.3")
    Agent.update(c.faults, &Map.put(&1, :history, :unavailable))
    view |> element("button", "Refresh") |> render_click()
    assert render(view) =~ "service could not complete"
    assert has_element?(view, ".reading", "24.3")
    render_click(view, "unknown-event")
    {:ok, _, html} = live(c.conn, "/")
    assert html =~ "Workshop sensor"
  end

  test "stable URLs are established before a mutation and unrelated receipts never claim success",
       c do
    {thing, enrollment_operation} = enrolled(c)
    {:ok, enrollment} = Service.get(c.service, c.admin, c.scope, "enrollments", thing, c.now)
    observation = enrollment["value"]["observation_id"]

    assert {:error, {:redirect, %{to: observation_url}}} =
             live(c.conn, Presenter.path(:observation, observation))

    assert observation_url =~ "?operation="
    assert {:error, {:redirect, %{to: asset_url}}} = live(c.conn, Presenter.path(:asset, thing))
    assert asset_url =~ "?operation="

    {:ok, asset, _} =
      live(c.conn, Presenter.path(:asset, thing) <> "?operation=" <> enrollment_operation)

    assert render(asset) =~ "different workflow"
    refute has_element?(asset, "button", "Provision Thing")

    import_operation = Identifier.uuid()

    {:ok, imported} =
      Service.submit(
        c.service,
        c.admin,
        c.scope,
        import_operation,
        import_request(%{id: "another"}, "2"),
        c.now
      )

    other = imported["data"]["observation_id"]

    for reference <- [enrollment_operation, import_operation] do
      {:ok, view, _} =
        live(c.conn, Presenter.path(:observation, other) <> "?operation=" <> reference)

      assert render(view) =~ "different workflow"
      refute has_element?(view, "#enroll")
    end
  end

  test "idle views reauthorize and revoked sessions close without another user action", c do
    {:ok, %{"id" => reader}} = Sessions.login(c.sessions, c.reader, c.scope)
    conn = build_conn() |> init_test_session(%{"browser_session" => reader})
    {:ok, view, _} = live(conn, "/")
    send(view.pid, :check_authority)
    assert render(view) =~ "Your assets"

    {:ok, _} =
      Service.revoke(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        %{"credential_id" => "reader", "expected_generation" => "0"},
        c.now
      )

    send(view.pid, :check_authority)
    assert_redirect(view, "/sign-in")
  end

  test "failed sign-in never reflects a credential and HTTP sign-out invalidates old view payloads",
       c do
    failed =
      build_conn()
      |> put_private(:plug_skip_csrf_protection, true)
      |> post("/session", %{token: "private-invalid-token", scope: c.scope})

    assert html_response(failed, 401) =~ "Sign-in failed"
    refute failed.resp_body =~ "private-invalid-token"

    signed_out =
      c.conn |> put_private(:plug_skip_csrf_protection, true) |> post("/session/logout", %{})

    assert redirected_to(signed_out) == "/sign-in"

    assert {:error, %{"code" => "unauthorized"}} =
             Sessions.request(c.sessions, c.session, :authorize)

    assert ErrorHTML.render("404.html", %{private: c.admin}) ==
             "This page is not available."

    refute ErrorHTML.render("500.html", %{private: c.admin}) =~ c.admin
  end

  test "missing records and malformed asset requests cannot expose provisioning controls", c do
    for path <- [
          "/assets/missing?operation=invalid",
          "/assets/missing?operation=" <> Identifier.uuid(),
          "/observations/missing?operation=" <> Identifier.uuid()
        ] do
      {:ok, view, _} = live(c.conn, path)
      assert has_element?(view, "[role=alert]")
      refute has_element?(view, "#enroll")
      refute has_element?(view, "button", "Provision Thing")
    end
  end

  defp imported(c) do
    {:ok, result} =
      Service.submit(c.service, c.admin, c.scope, Identifier.uuid(), import_request(), c.now)

    result["data"]["observation_id"]
  end

  defp upload_capture(view, bytes) do
    upload =
      file_input(view, "#import-capture", :observation, [
        %{name: "observation.json", content: bytes, type: "application/json"}
      ])

    render_upload(upload, "observation.json")
  end

  defp enrolled(c) do
    observation = imported(c)
    operation = Identifier.uuid()

    {:ok, result} =
      Service.enroll(
        c.service,
        c.admin,
        c.scope,
        operation,
        %{
          "observation_id" => observation,
          "title" => "Workshop sensor",
          "owner_confirmed" => true,
          "expected_generation" => "1"
        },
        c.now
      )

    {result["data"]["thing_id"], operation}
  end
end
