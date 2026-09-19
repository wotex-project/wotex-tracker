defmodule Wotex.Tracker.UI.WorkflowTest do
  @moduledoc false
  use ExUnit.Case, async: false
  import Plug.Conn
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Wotex.Tracker.Service.Fixtures
  alias Phoenix.LiveView.Static

  alias Wotex.Tracker.{
    Evidence,
    EvidenceBundle,
    HeartbeatTransition,
    Observation,
    PolicyFact,
    QueryResult,
    QuerySpec
  }

  alias Wotex.Tracker.Service

  alias Wotex.Tracker.Service.{
    Codec,
    Identifier,
    Projection,
    RuleFixtures,
    RuleTransition,
    Store,
    Update
  }

  alias Wotex.Tracker.UI.{ErrorHTML, Presenter, PromptPeer, Sessions, TestClient, TestEndpoint}
  @endpoint TestEndpoint

  setup do
    c = service()
    faults = start_supervised!({Agent, fn -> %{} end})

    prompt =
      start_supervised!(
        {Agent, fn -> %{response: {:error, %{"code" => "prompt_unavailable"}}, calls: []} end},
        id: :prompt_peer
      )

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
       tracker_ui: [sessions: sessions, prompt: {PromptPeer, prompt}, operational_history: true]}
    )

    {:ok, %{"id" => id}} = Sessions.login(sessions, c.admin, c.scope)
    conn = build_conn() |> init_test_session(%{"browser_session" => id})
    Map.merge(c, %{sessions: sessions, session: id, conn: conn, faults: faults, prompt: prompt})
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

  test "asset overview shows each provisioned asset's rule status", c do
    thing = provisioned(c)
    {:ok, view, _} = live(c.conn, "/")
    assert has_element?(view, ".card p", "No protection rules defined.")

    {:ok, _} =
      Service.save_policy(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        battery_rule(thing, "3", {3.0, 3.2}),
        c.now
      )

    view |> element("button", "Refresh") |> render_click()
    assert has_element?(view, ".rule-summary li", "Low battery: Low")
    assert has_element?(view, ".rule-summary li strong", "needs attention")

    Agent.update(c.faults, &Map.put(&1, :thing_rules, :unavailable))
    view |> element("button", "Refresh") |> render_click()
    assert has_element?(view, ".card [role=status]", "Rule status unavailable")
    assert has_element?(view, ".card .summary-values li", "Temperature: 24.3 °C")

    Agent.update(c.faults, &Map.put(&1, :thing_rules, {:deny, "forbidden"}))
    view |> element("button", "Refresh") |> render_click()
    refute has_element?(view, ".card")
    assert has_element?(view, "[role=alert]")
  end

  test "asset overview distinguishes unprovisioned, retained and unavailable readings", c do
    {thing, _} = enrolled(c)
    {:ok, view, _} = live(c.conn, "/")
    assert has_element?(view, ".card", "No committed measurements yet")
    refute render(view) =~ "24.3"

    {:ok, _} =
      Service.materialize(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        %{"thing_id" => thing, "expected_generation" => "2"},
        c.now
      )

    view |> element("button", "Refresh") |> render_click()
    assert has_element?(view, ".card .summary-values li", "Temperature: 24.3 °C")
    assert render(view) =~ "current device connectivity is unknown"
    assert render(view) =~ "Last recorded"

    Agent.update(c.faults, &Map.put(&1, :get, :unavailable))
    view |> element("button", "Refresh") |> render_click()
    assert has_element?(view, ".card [role=status]", "Measurement summary unavailable")
    refute render(view) =~ "24.3"

    view |> element("button", "Refresh") |> render_click()
    assert has_element?(view, ".card .summary-values li", "Temperature: 24.3 °C")

    Agent.update(c.faults, &Map.put(&1, :get, {:deny, "forbidden"}))
    view |> element("button", "Refresh") |> render_click()
    refute has_element?(view, ".card")
    assert has_element?(view, "[role=alert]")

    view |> element("button", "Refresh") |> render_click()
    assert has_element?(view, ".card .summary-values li", "Temperature: 24.3 °C")

    {:ok, current} = Service.list(c.service, c.admin, c.scope, "observations", %{}, c.now)

    {:ok, imported} =
      Service.submit(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        import_request(%{id: "later-overview", observed_at: c.now + 1}, current["generation"]),
        c.now
      )

    {:ok, current} = Service.list(c.service, c.admin, c.scope, "enrollments", %{}, c.now)

    {:ok, _} =
      Service.associate(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        %{
          "thing_id" => thing,
          "observation_id" => imported["data"]["observation_id"],
          "owner_confirmed" => true,
          "expected_generation" => current["generation"]
        },
        c.now
      )

    view |> element("button", "Refresh") |> render_click()
    assert render(view) =~ "prior associated observation"

    {:ok, %{"id" => reader}} = Sessions.login(c.sessions, c.reader, c.scope)
    conn = build_conn() |> init_test_session(%{"browser_session" => reader})
    {:ok, reader_view, _} = live(conn, "/")
    assert has_element?(reader_view, ".card .summary-values li", "Temperature: 24.3 °C")

    Agent.update(c.faults, &Map.put(&1, :list, {:deny, "forbidden"}))
    view |> element("button", "Refresh") |> render_click()
    refute has_element?(view, ".card")
    assert has_element?(view, "[role=alert]")

    view |> element("button", "Refresh") |> render_click()
    assert has_element?(view, ".card .summary-values li", "Temperature: 24.3 °C")
  end

  test "asset overview, details and retained history present authorized position projections",
       c do
    thing = provisioned(c)
    {:ok, %{"value" => state}} = Service.get(c.service, c.admin, c.scope, "state", thing, c.now)
    {:ok, access} = Service.authorize(c.service, c.admin, c.scope, "ingest", c.now)
    position = public_position(c.now)

    {:ok, update} =
      Update.new(%{
        principal: access.principal,
        scope: c.scope,
        authority: access,
        operation_id: Identifier.uuid(),
        expected_generation: "3",
        request: %{"operation" => "position-ui-fixture"},
        now: c.now,
        observation: nil,
        records: [
          %{kind: "state", id: thing, value: %{"public" => %{state | "positions" => [position]}}}
        ],
        events: [],
        publication: nil
      })

    assert {:ok, _} = Store.mutate(c.store, update)
    {:ok, overview, _} = live(c.conn, "/")
    assert has_element?(overview, ".position-summary li", "GNSS: 59.3293, 18.0686")
    assert render(overview) =~ "Retained readings and positions"

    {:ok, asset, _} =
      live(c.conn, Presenter.path(:asset, thing) <> "?operation=" <> Identifier.uuid())

    assert has_element?(asset, "#positions-title", "Recorded positions")
    assert has_element?(asset, ".position .coordinates", "bound accuracy 5.0 m")
    assert render(asset) =~ "has not selected a canonical source"
    assert has_element?(asset, "tbody td li", "GNSS: 59.3293, 18.0686")
    refute render(asset) =~ "private-position-source"
  end

  test "terminal read denials clear retained detail and setup evidence", c do
    {thing, _} = enrolled(c)
    {:ok, enrollment} = Service.get(c.service, c.admin, c.scope, "enrollments", thing, c.now)
    observation = enrollment["value"]["observation_id"]

    {:ok, _} =
      Service.materialize(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        %{"thing_id" => thing, "expected_generation" => "2"},
        c.now
      )

    {:ok, asset, _} =
      live(c.conn, Presenter.path(:asset, thing) <> "?operation=" <> Identifier.uuid())

    assert has_element?(asset, ".reading", "24.3")
    assert has_element?(asset, "h2", "Measurement history")
    Agent.update(c.faults, &Map.put(&1, :history, {:deny, "forbidden"}))
    asset |> element("button", "Refresh") |> render_click()
    refute has_element?(asset, ".reading")
    refute has_element?(asset, "h2", "Measurement history")
    refute render(asset) =~ "Workshop sensor"
    assert has_element?(asset, "[role=alert]")
    asset |> element("button", "Refresh") |> render_click()
    assert has_element?(asset, ".reading", "24.3")
    refute has_element?(asset, "[role=alert]")

    {:ok, evidence, _} =
      live(
        c.conn,
        Presenter.path(:observation, observation) <> "?operation=" <> Identifier.uuid()
      )

    assert has_element?(evidence, "#enroll")
    Agent.update(c.faults, &Map.put(&1, :get, {:deny, "forbidden"}))
    evidence |> element("button", "Refresh evidence") |> render_click()
    refute has_element?(evidence, "#enroll")
    assert has_element?(evidence, "[role=alert]")
    evidence |> element("button", "Refresh evidence") |> render_click()
    assert has_element?(evidence, "#enroll")
    refute has_element?(evidence, "[role=alert]")

    {:ok, association, _} =
      live(
        c.conn,
        Presenter.association_path(thing, observation) <> "?operation=" <> Identifier.uuid()
      )

    assert has_element?(association, "#associate")
    Agent.update(c.faults, &Map.put(&1, :get, {:deny, "forbidden"}))
    association |> element("button", "Refresh evidence") |> render_click()
    refute has_element?(association, "#associate")
    refute render(association) =~ "Workshop sensor"
    assert has_element?(association, "[role=alert]")
    association |> element("button", "Refresh evidence") |> render_click()
    assert has_element?(association, "#associate")
    refute has_element?(association, "[role=alert]")

    {:ok, picker, _} = live(c.conn, Presenter.path(:asset, thing) <> "/observations")
    assert has_element?(picker, "a", "Inspect observation")
    Agent.update(c.faults, &Map.put(&1, :list, {:deny, "forbidden"}))
    picker |> element("button", "Refresh") |> render_click()
    refute has_element?(picker, "a", "Inspect observation")
    assert has_element?(picker, "[role=alert]")
    picker |> element("button", "Refresh") |> render_click()
    assert has_element?(picker, "a", "Inspect observation")
    refute has_element?(picker, "[role=alert]")

    Agent.update(c.faults, &Map.put(&1, :get, :unavailable))
    picker |> element("button", "Refresh") |> render_click()
    assert has_element?(picker, "a", "Inspect observation")
    assert has_element?(picker, "[role=alert]")
    picker |> element("button", "Refresh") |> render_click()
    refute has_element?(picker, "[role=alert]")

    Agent.update(c.faults, &Map.put(&1, :get, {:deny, "forbidden"}))
    picker |> element("button", "Refresh") |> render_click()
    refute has_element?(picker, "a", "Inspect observation")
    assert has_element?(picker, "[role=alert]")
  end

  test "history export rechecks the exact visible page and omits session cursors", c do
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

    {:ok, page} = Service.history(c.service, c.admin, c.scope, "state", thing, %{}, c.now)

    {:ok, asset, _} =
      live(c.conn, Presenter.path(:asset, thing) <> "?operation=" <> Identifier.uuid())

    asset |> element("button", "Export this history page (JSON)") |> render_click()
    assert_push_event(asset, "download-history-page", %{"content" => json})
    document = Jason.decode!(json)
    assert document["schema"] == "wtr.history-page-export.v1"
    assert document["resource"] == "state"
    assert document["asset_id"] == thing
    assert document["snapshot_generation"] == page["generation"]
    assert document["items"] == page["items"]
    assert document["page_count"] == length(page["items"])
    assert document["has_more"] == false
    refute Map.has_key?(document, "cursor")
    refute Map.has_key?(document, "stream_cursor")

    Agent.update(c.faults, &Map.put(&1, :history, :unavailable))
    asset |> element("button", "Export this history page (JSON)") |> render_click()
    refute_push_event(asset, "download-history-page", %{"content" => _})
    assert has_element?(asset, "[role=alert]")
    asset |> element("button", "Export this history page (JSON)") |> render_click()
    assert_push_event(asset, "download-history-page", %{"content" => _})

    {:ok, imported} =
      Service.submit(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        import_request(%{id: "later", observed_at: c.now + 1}, "3"),
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
          "observation_id" => imported["data"]["observation_id"],
          "owner_confirmed" => true,
          "expected_generation" => "4"
        },
        c.now
      )

    {:ok, _} =
      Service.materialize(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        %{"thing_id" => thing, "expected_generation" => "5"},
        c.now
      )

    asset |> element("button", "Export this history page (JSON)") |> render_click()
    refute_push_event(asset, "download-history-page", %{"content" => _})
    refute has_element?(asset, "button", "Export this history page (JSON)")
    assert render(asset) =~ "changed since this page loaded"

    asset |> element("button", "Refresh") |> render_click()
    assert has_element?(asset, "button", "Export this history page (JSON)")
    Agent.update(c.faults, &Map.put(&1, :history, {:deny, "forbidden"}))
    asset |> element("button", "Export this history page (JSON)") |> render_click()
    refute_push_event(asset, "download-history-page", %{"content" => _})
    refute has_element?(asset, ".reading")
    assert has_element?(asset, "[role=alert]")

    render_click(asset, "export-history")
    refute_push_event(asset, "download-history-page", %{"content" => _})
    refute has_element?(asset, "button", "Export this history page (JSON)")

    render_click(asset, "export-all-history")
    refute_push_event(asset, "download-history", %{"content" => _})
  end

  test "raw capture and evidence downloads require the separate grant on every click", c do
    observation = imported(c)
    path = Presenter.path(:observation, observation) <> "?operation=" <> Identifier.uuid()
    {:ok, view, html} = live(c.conn, path)
    assert html =~ "Private evidence export"
    refute html =~ "private-hardware"

    {:ok, native} = Service.raw_observation(c.service, c.admin, c.scope, observation, c.now)
    {:ok, claims} = Service.raw_evidence(c.service, c.admin, c.scope, observation, c.now)

    view |> element("button", "Export native observation (JSON)") |> render_click()
    assert_push_event(view, "download-raw-observation", %{"content" => ^native})

    view |> element("button", "Export raw evidence claims (JSON)") |> render_click()
    assert_push_event(view, "download-raw-evidence", %{"content" => ^claims})
    refute render(view) =~ "private-hardware"

    Agent.update(c.faults, &Map.put(&1, :raw_observation, {:deny, "forbidden"}))
    view |> element("button", "Export native observation (JSON)") |> render_click()
    refute_push_event(view, "download-raw-observation", %{"content" => _})
    assert has_element?(view, "[role=alert]")
    assert has_element?(view, "h2", "Observation evidence")
    assert has_element?(view, "#enroll")

    Agent.update(
      c.faults,
      &Map.put(&1, :raw_observation, {:reply, {:ok, String.duplicate("x", 1_048_577)}})
    )

    view |> element("button", "Export native observation (JSON)") |> render_click()
    refute_push_event(view, "download-raw-observation", %{"content" => _})

    Agent.update(c.faults, &Map.put(&1, :raw_observation, {:reply, {:ok, %{}}}))
    view |> element("button", "Export native observation (JSON)") |> render_click()
    refute_push_event(view, "download-raw-observation", %{"content" => _})

    Agent.update(c.faults, &Map.put(&1, :raw_observation, {:reply, {:ok, "not json"}}))
    view |> element("button", "Export native observation (JSON)") |> render_click()
    refute_push_event(view, "download-raw-observation", %{"content" => _})

    {:ok, %{"id" => reader}} = Sessions.login(c.sessions, c.reader, c.scope)
    conn = build_conn() |> init_test_session(%{"browser_session" => reader})
    {:ok, reader_view, _} = live(conn, path)
    refute has_element?(reader_view, "button", "Export native observation (JSON)")
    refute has_element?(reader_view, "button", "Export raw evidence claims (JSON)")

    render_click(reader_view, "export-raw", %{"kind" => "observation"})
    refute_push_event(reader_view, "download-raw-observation", %{"content" => _})
    assert has_element?(reader_view, "[role=alert]")

    assert {:error, %{"code" => "forbidden"}} =
             Sessions.request(c.sessions, reader, :raw_observation, %{"id" => observation})
  end

  test "the browser shows current access without exposing the bearer", c do
    {:ok, view, html} = live(c.conn, "/access")
    assert html =~ "Access and session"
    assert html =~ "owner"
    assert html =~ "workshop"
    assert html =~ "Export raw evidence"
    assert has_element?(view, "tbody tr:nth-child(4) td", "Allowed")
    refute html =~ c.admin

    Agent.update(c.faults, &Map.put(&1, :access, :unavailable))
    view |> element("button", "Refresh access") |> render_click()
    assert has_element?(view, "[role=alert]")
    assert render(view) =~ "owner"

    Agent.update(c.faults, &Map.put(&1, :access, {:deny, "forbidden"}))
    view |> element("button", "Refresh access") |> render_click()
    refute render(view) =~ "owner"
    assert has_element?(view, "[role=alert]")

    {:ok, %{"id" => reader}} = Sessions.login(c.sessions, c.reader, c.scope)
    conn = build_conn() |> init_test_session(%{"browser_session" => reader})
    {:ok, reader_view, _} = live(conn, "/access")
    assert render(reader_view) =~ "viewer"
    assert has_element?(reader_view, "tbody tr:nth-child(4) td", "Not allowed")
    refute render(reader_view) =~ c.reader
  end

  test "the activity page pages recent committed changes with links to what changed", c do
    thing = provisioned(c)

    save = fn request ->
      Service.save_policy(c.service, c.admin, c.scope, Identifier.uuid(), request, c.now)
    end

    {:ok, _} = save.(battery_rule(thing, generation(c), {2.5, 2.8}))
    {:ok, _} = save.(battery_rule(thing, generation(c), {3.0, 3.2}))

    {:ok, %{"items" => [%{"id" => alert} | _]}} =
      Service.thing_alerts(c.service, c.reader, c.scope, thing, %{}, c.now)

    {:ok, _} =
      Service.acknowledge_alert(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        %{"alert_id" => alert, "expected_generation" => generation(c)},
        c.now
      )

    {dashboard, _} = saved_dashboard(c, thing)

    {:ok, _} =
      Service.delete_query(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        %{"id" => dashboard, "expected_generation" => generation(c)},
        c.now
      )

    {:ok, _} =
      Service.delete_policy(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        %{"id" => "low-battery", "expected_generation" => generation(c)},
        c.now
      )

    {:ok, _} =
      Service.revoke(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        %{"credential_id" => "reader", "expected_generation" => generation(c)},
        c.now
      )

    {:ok, _} =
      Service.unenroll(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        %{"thing_id" => thing, "expected_generation" => generation(c)},
        c.now
      )

    {:ok, _layout, html} = live(c.conn, "/")
    assert html =~ ~s(<a href="/activity">Activity</a>)

    {:ok, view, _} = live(c.conn, "/activity")
    first = render(view)
    assert first =~ "Removed asset"
    assert first =~ "Revoked credential"
    assert has_element?(view, ~s(a[href="#{Presenter.alert_path(alert)}"]), "Acknowledged alert")
    assert first =~ "Deleted dashboard"

    assert has_element?(
             view,
             ~s(a[href="#{Presenter.dashboard_path(dashboard)}"]),
             "Saved dashboard"
           )

    refute has_element?(view, "button", "Newer changes")

    Agent.update(c.faults, &Map.put(&1, :operations, :unavailable))
    view |> element("button", "Older changes") |> render_click()
    assert has_element?(view, "[role=alert]")
    assert render(view) =~ "Removed asset"

    view |> element("button", "Older changes") |> render_click()
    assert has_element?(view, "a", "Imported observation")
    refute render(view) =~ "Removed asset"

    view |> element("button", "Newer changes") |> render_click()
    assert render(view) =~ "Removed asset"

    view |> element("button", "Older changes") |> render_click()
    commit_change(c, "activity")
    view |> element("button", "Newer changes") |> render_click()
    assert has_element?(view, "[role=alert]", "service changed")

    Agent.update(c.faults, &Map.put(&1, :operations, {:reply, {:ok, %{}}}))
    view |> element("button", "Refresh") |> render_click()
    assert has_element?(view, "[role=alert]")

    Agent.update(c.faults, &Map.put(&1, :operations, {:deny, "forbidden"}))
    view |> element("button", "Refresh") |> render_click()
    refute has_element?(view, "table")

    view |> element("button", "Refresh") |> render_click()
    assert render(view) =~ "Imported observation"
  end

  test "a browser ends another session of the same credential from the access page", c do
    {:ok, %{"id" => other}} = Sessions.login(c.sessions, c.admin, c.scope)
    {:ok, view, html} = live(c.conn, "/access")
    assert has_element?(view, "caption", "Browser sessions: 2")
    assert has_element?(view, "td span", "This browser")
    refute html =~ c.session
    refute html =~ other

    view |> element("button", "End session") |> render_click()
    assert has_element?(view, "caption", "Browser sessions: 1")
    refute has_element?(view, "button", "End session")
    assert {:error, %{"code" => "unauthorized"}} = Sessions.request(c.sessions, other, :authorize)
    assert {:ok, _} = Sessions.request(c.sessions, c.session, :authorize)

    render_click(view, "end-session", %{"handle" => "missing"})
    assert has_element?(view, "[role=alert]", "not available")
    assert has_element?(view, "caption", "Browser sessions: 1")
  end

  test "an administrator can revoke the current credential after explicit confirmation", c do
    {:ok, view, _} = live(c.conn, "/access")
    assert has_element?(view, "button", "Prepare revocation")

    view |> element("button", "Prepare revocation") |> render_click()
    assert has_element?(view, "#revoke-current")
    refute render(view) =~ c.admin

    render_submit(view, "confirm-revoke", %{"revoke" => %{}})
    assert has_element?(view, "[role=alert]", "Check the required fields")
    assert {:ok, _} = Service.authorize(c.service, c.admin, c.scope, "read", c.now)

    result = view |> form("#revoke-current", revoke: %{confirmed: "yes"}) |> render_submit()
    assert_redirect(view, "/sign-in")
    assert {:ok, sign_in} = follow_redirect(result, c.conn, "/sign-in")
    assert html_response(sign_in, 200) =~ "Credential revoked"

    assert {:error, %{"code" => "unauthorized"}} =
             Sessions.request(c.sessions, c.session, :access)

    assert {:error, :unauthorized} = Service.authorize(c.service, c.admin, c.scope, "read", c.now)
  end

  test "a stale revocation refuses to remove access", c do
    {:ok, view, _} = live(c.conn, "/access")
    view |> element("button", "Prepare revocation") |> render_click()

    assert {:ok, _} =
             Service.submit(
               c.service,
               c.admin,
               c.scope,
               Identifier.uuid(),
               import_request(),
               c.now
             )

    view |> form("#revoke-current", revoke: %{confirmed: "yes"}) |> render_submit()
    assert has_element?(view, "[role=alert]", "service changed")
    refute has_element?(view, "#revoke-current")
    assert {:ok, _} = Service.authorize(c.service, c.admin, c.scope, "read", c.now)
  end

  test "revocation preparation and submission failures leave the credential valid", c do
    {:ok, view, _} = live(c.conn, "/access")

    render_submit(view, "confirm-revoke", %{"revoke" => %{"confirmed" => "yes"}})
    assert has_element?(view, "[role=alert]", "Check the required fields")

    Agent.update(c.faults, &Map.put(&1, :revocation_context, :unavailable))
    view |> element("button", "Prepare revocation") |> render_click()
    assert has_element?(view, "[role=alert]")
    refute has_element?(view, "#revoke-current")

    view |> element("button", "Prepare revocation") |> render_click()
    assert has_element?(view, "#revoke-current")
    view |> element("button", "Cancel") |> render_click()
    refute has_element?(view, "#revoke-current")

    view |> element("button", "Prepare revocation") |> render_click()
    Agent.update(c.faults, &Map.put(&1, :revoke, :unavailable))
    view |> form("#revoke-current", revoke: %{confirmed: "yes"}) |> render_submit()
    assert has_element?(view, "[role=alert]")
    refute has_element?(view, "#revoke-current")
    assert {:ok, _} = Service.authorize(c.service, c.admin, c.scope, "read", c.now)
  end

  test "malformed revocation replies never authorize an unconfirmed mutation", c do
    {:ok, view, _} = live(c.conn, "/access")

    Agent.update(c.faults, &Map.put(&1, :revocation_context, {:reply, {:ok, %{}}}))
    view |> element("button", "Prepare revocation") |> render_click()
    assert has_element?(view, "[role=alert]")
    refute has_element?(view, "#revoke-current")

    view |> element("button", "Prepare revocation") |> render_click()
    Agent.update(c.faults, &Map.put(&1, :revoke, {:reply, {:ok, %{}}}))
    view |> form("#revoke-current", revoke: %{confirmed: "yes"}) |> render_submit()
    assert has_element?(view, "[role=alert]")
    assert has_element?(view, "#revoke-current")
    assert {:ok, _} = Service.authorize(c.service, c.admin, c.scope, "read", c.now)

    view |> element("button", "Refresh access") |> render_click()
    refute has_element?(view, "#revoke-current")
  end

  test "an administrator reviews scope credentials and revokes another after confirmation", c do
    {:ok, view, html} = live(c.conn, "/access")
    assert has_element?(view, "caption", "2 configured credentials at scope version 0")
    assert has_element?(view, "th .identifier", "This browser session")
    assert has_element?(view, ~s(button[phx-value-id="reader"]), "Prepare to revoke")
    refute has_element?(view, ~s(button[phx-value-id="admin"]))
    assert html =~ "viewer"
    refute html =~ "token_sha256"
    refute html =~ c.admin
    refute html =~ c.reader

    view |> element(~s(button[phx-value-id="reader"])) |> render_click()
    patched = assert_patch(view)
    assert URI.decode_query(URI.parse(patched).query)["credential"] == "reader"
    assert has_element?(view, "#revoke-other")
    refute has_element?(view, ~s(button[phx-value-id="reader"]))

    render_submit(view, "confirm-revoke-other", %{"revoke" => %{}})
    assert has_element?(view, "[role=alert]", "Check the required fields")
    assert {:ok, _} = Service.authorize(c.service, c.reader, c.scope, "read", c.now)

    view |> form("#revoke-other", revoke: %{confirmed: "yes"}) |> render_submit()
    assert has_element?(view, "[role=status]", "Credential reader revoked")
    refute has_element?(view, "#revoke-other")
    assert render(view) =~ "Revoked 2023-11-14 22:13:20 UTC by owner"

    assert {:error, :unauthorized} =
             Service.authorize(c.service, c.reader, c.scope, "read", c.now)

    assert {:ok, _} = Service.authorize(c.service, c.admin, c.scope, "read", c.now)

    {:ok, resumed, _} = live(c.conn, patched)
    assert has_element?(resumed, "[role=status]", "Credential reader revoked")
    refute has_element?(resumed, "#revoke-other")
    render_submit(resumed, "confirm-revoke-other", %{"revoke" => %{"confirmed" => "yes"}})
    refute has_element?(resumed, "[role=alert]")

    assert {:ok, %{"generation" => "1"}} =
             Service.credentials(c.service, c.admin, c.scope, c.now)

    {:ok, other, _} = live(c.conn, "/access?credential=reader&operation=" <> Identifier.uuid())
    assert render(other) =~ "cannot be revoked here"
    refute has_element?(other, "#revoke-other")
    render_submit(other, "confirm-revoke-other", %{"revoke" => %{"confirmed" => "yes"}})
    assert has_element?(other, "[role=alert]", "service changed")
    other |> element("button", "Check operation outcome") |> render_click()
    refute has_element?(other, "[role=status]")
  end

  test "credential revocation recovers lost replies and refuses stale or forged changes", c do
    {:ok, view, _} = live(c.conn, "/access")
    view |> element(~s(button[phx-value-id="reader"])) |> render_click()
    stale_path = assert_patch(view)
    import_operation = Identifier.uuid()

    assert {:ok, _} =
             Service.submit(
               c.service,
               c.admin,
               c.scope,
               import_operation,
               import_request(),
               c.now
             )

    view |> form("#revoke-other", revoke: %{confirmed: "yes"}) |> render_submit()
    assert has_element?(view, "[role=alert]", "service changed")
    refute has_element?(view, "#revoke-other")
    assert {:ok, _} = Service.authorize(c.service, c.reader, c.scope, "read", c.now)

    {:ok, unrelated, _} =
      live(c.conn, "/access?credential=reader&operation=" <> import_operation)

    assert has_element?(unrelated, "[role=alert]", "different workflow")
    refute has_element?(unrelated, "#revoke-other")

    {:ok, invalid, _} = live(c.conn, "/access?credential=reader&operation=not-a-uuid")
    assert has_element?(invalid, "[role=alert]")
    refute has_element?(invalid, "#revoke-other")
    {:ok, partial, _} = live(c.conn, "/access?credential=reader")
    assert has_element?(partial, "[role=alert]")

    render_click(invalid, "prepare-revoke-other", %{"id" => "admin"})
    assert has_element?(invalid, "[role=alert]", "service changed")

    {:ok, unavailable, _} = live(c.conn, "/access")
    Agent.update(c.faults, &Map.put(&1, :credentials, :unavailable))
    unavailable |> element("button", "Refresh access") |> render_click()
    assert has_element?(unavailable, "[role=status]", "credential list is unavailable")
    refute has_element?(unavailable, ~s(button[phx-value-id="reader"]))
    Agent.update(c.faults, &Map.put(&1, :credentials, :unavailable))
    render_click(unavailable, "prepare-revoke-other", %{"id" => "reader"})
    assert has_element?(unavailable, "[role=alert]")
    unavailable |> element("button", "Refresh access") |> render_click()
    assert has_element?(unavailable, ~s(button[phx-value-id="reader"]))

    Agent.update(c.faults, &Map.put(&1, :credentials, {:reply, {:ok, %{}}}))
    unavailable |> element("button", "Refresh access") |> render_click()
    assert has_element?(unavailable, "[role=status]", "credential list is unavailable")

    {:ok, lost, _} = live(c.conn, "/access")
    lost |> element(~s(button[phx-value-id="reader"])) |> render_click()
    lost_path = assert_patch(lost)
    refute lost_path == stale_path
    Agent.update(c.faults, &Map.put(&1, :revoke, :lost_reply))
    lost |> form("#revoke-other", revoke: %{confirmed: "yes"}) |> render_submit()
    assert has_element?(lost, "[role=status]", "Revocation outcome unknown")
    refute has_element?(lost, "#revoke-other")

    Agent.update(c.faults, &Map.put(&1, :credentials, :unavailable))
    lost |> element("button", "Check operation outcome") |> render_click()
    assert has_element?(lost, "[role=status]", "Revocation outcome unknown")
    lost |> element("button", "Check operation outcome") |> render_click()
    assert has_element?(lost, "[role=status]", "Credential reader revoked")

    {:ok, reconnect, _} = live(c.conn, lost_path)
    assert has_element?(reconnect, "[role=status]", "Credential reader revoked")
    Agent.update(c.faults, &Map.put(&1, :operation, :unavailable))
    reconnect |> element("button", "Check operation outcome") |> render_click()
    assert has_element?(reconnect, "[role=status]", "Credential reader revoked")
    assert has_element?(reconnect, "[role=alert]")
    reconnect |> element("button", "Check operation outcome") |> render_click()
    assert has_element?(reconnect, "[role=status]", "Credential reader revoked")
    refute has_element?(reconnect, "[role=alert]")
  end

  test "a reader cannot see scope credentials or forge another revocation", c do
    {:ok, %{"id" => reader}} = Sessions.login(c.sessions, c.reader, c.scope)
    conn = build_conn() |> init_test_session(%{"browser_session" => reader})
    {:ok, view, html} = live(conn, "/access")
    refute html =~ "Credentials in this scope"
    refute html =~ "owner"
    render_click(view, "prepare-revoke-other", %{"id" => "admin"})
    assert has_element?(view, "[role=alert]", "does not permit")

    {:ok, forged, _} = live(conn, "/access?credential=admin&operation=" <> Identifier.uuid())
    refute has_element?(forged, "#revoke-other")
    render_submit(forged, "confirm-revoke-other", %{"revoke" => %{"confirmed" => "yes"}})
    assert has_element?(forged, "[role=alert]", "does not permit")
    assert {:ok, _} = Service.authorize(c.service, c.admin, c.scope, "read", c.now)

    {:ok, admin_view, _} = live(c.conn, "/access")
    admin_view |> element(~s(button[phx-value-id="reader"])) |> render_click()
    admin_view |> element("button", "Cancel revocation") |> render_click()
    assert_patch(admin_view, "/access")
    refute has_element?(admin_view, "#revoke-other")
  end

  test "a reader cannot prepare or forge a self-revocation", c do
    {:ok, %{"id" => reader}} = Sessions.login(c.sessions, c.reader, c.scope)
    conn = build_conn() |> init_test_session(%{"browser_session" => reader})
    {:ok, view, _} = live(conn, "/access")
    refute has_element?(view, "button", "Prepare revocation")

    render_click(view, "prepare-revoke", %{})
    assert has_element?(view, "[role=alert]", "does not permit")

    assert {:error, %{"code" => "forbidden"}} =
             Sessions.request(c.sessions, reader, :revocation_context)
  end

  test "an uncertain self-revocation retains its operation reference", c do
    {:ok, view, _} = live(c.conn, "/access")
    view |> element("button", "Prepare revocation") |> render_click()

    operation =
      view
      |> render()
      |> then(&Regex.run(~r/Operation reference <code>([^<]+)/, &1))
      |> Enum.at(1)

    Agent.update(c.faults, &Map.put(&1, :revoke, :lost_reply))
    result = view |> form("#revoke-current", revoke: %{confirmed: "yes"}) |> render_submit()
    assert {:ok, sign_in} = follow_redirect(result, c.conn, "/sign-in")
    assert html_response(sign_in, 200) =~ operation
    assert html_response(sign_in, 200) =~ "outcome unknown"
    refute html_response(sign_in, 200) =~ c.admin
    assert {:error, :unauthorized} = Service.authorize(c.service, c.admin, c.scope, "read", c.now)
  end

  test "history pages can be revisited without losing the current page on failure", c do
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

    {:ok, %{"value" => state}} =
      Service.get(c.service, c.admin, c.scope, "state", thing, c.now)

    {:ok, access} = Service.authorize(c.service, c.admin, c.scope, "ingest", c.now)

    for step <- 1..25, do: append_history_state(c, thing, state, access, step)

    {:ok, asset, _} =
      live(c.conn, Presenter.path(:asset, thing) <> "?operation=" <> Identifier.uuid())

    assert has_element?(asset, "tbody tr:first-child td:first-child", "3")
    assert has_element?(asset, "button", "Next history page")
    refute has_element?(asset, "button", "Previous history page")

    asset |> element("button", "Export retained history (JSON)") |> render_click()
    assert_push_event(asset, "download-history", %{"content" => complete_json})
    complete = Jason.decode!(complete_json)
    assert complete["schema"] == "wtr.history-export.v1"
    assert complete["snapshot_generation"] == "28"
    assert complete["item_count"] == 26
    assert complete["page_count"] == 1
    assert complete["complete"] == true
    assert Enum.map(complete["items"], & &1["generation"]) == Enum.map(3..28, &to_string/1)
    refute complete_json =~ "wtrc1."

    Agent.update(c.faults, &Map.put(&1, :history, :unavailable))
    asset |> element("button", "Export retained history (JSON)") |> render_click()
    refute_push_event(asset, "download-history", %{"content" => _})
    assert has_element?(asset, "[role=alert]")

    asset |> element("button", "Next history page") |> render_click()
    assert has_element?(asset, "tbody tr:first-child td:first-child", "28")
    assert has_element?(asset, "button", "Previous history page")
    refute has_element?(asset, "button", "Next history page")

    Agent.update(c.faults, &Map.put(&1, :history, :unavailable))
    asset |> element("button", "Previous history page") |> render_click()
    assert has_element?(asset, "tbody tr:first-child td:first-child", "28")
    assert has_element?(asset, "button", "Previous history page")

    asset |> element("button", "Previous history page") |> render_click()
    assert has_element?(asset, "tbody tr:first-child td:first-child", "3")
    refute has_element?(asset, "button", "Previous history page")
    assert has_element?(asset, "button", "Next history page")

    asset |> element("button", "Next history page") |> render_click()
    append_history_state(c, thing, state, access, 26)
    asset |> element("button", "Previous history page") |> render_click()
    assert has_element?(asset, "tbody tr:first-child td:first-child", "28")
    assert has_element?(asset, "button", "Previous history page")
    assert render(asset) =~ "changed since this page loaded"

    asset |> element("button", "Refresh") |> render_click()
    assert has_element?(asset, "tbody tr:first-child td:first-child", "3")
    refute has_element?(asset, "button", "Previous history page")

    Agent.update(c.faults, &Map.put(&1, :history, {:deny, "forbidden"}))
    asset |> element("button", "Next history page") |> render_click()
    refute has_element?(asset, "button", "Next history page")
    refute has_element?(asset, "button", "Previous history page")
    assert has_element?(asset, "[role=alert]")

    asset |> element("button", "Refresh") |> render_click()
    Agent.update(c.faults, &Map.put(&1, :history, {:deny, "forbidden"}))
    asset |> element("button", "Export retained history (JSON)") |> render_click()
    refute_push_event(asset, "download-history", %{"content" => _})
    refute has_element?(asset, "button", "Export retained history (JSON)")
  end

  test "a reader sees only declared Property controls and a committed read result", c do
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

    {:ok, %{"id" => reader}} = Sessions.login(c.sessions, c.reader, c.scope)
    conn = build_conn() |> init_test_session(%{"browser_session" => reader})

    {:ok, view, _} =
      live(conn, Presenter.path(:asset, thing) <> "?operation=" <> Identifier.uuid())

    assert has_element?(view, "button[phx-value-name='temperature']", "Read Temperature")
    refute has_element?(view, "button[phx-value-name='missing']")
    view |> element("button[phx-value-name='temperature']") |> render_click()
    assert has_element?(view, "p[role=status]", "Temperature: 24.3 °C · committed generation 3")
    assert render(view) =~ "does not contact the physical device"

    render_click(view, "read-property", %{"name" => "missing"})
    assert has_element?(view, "[role=alert]")
    refute has_element?(view, "p[role=status]")

    Agent.update(c.faults, &Map.put(&1, :read_property, :unavailable))
    view |> element("button[phx-value-name='pressure']") |> render_click()
    assert has_element?(view, "[role=alert]")
    view |> element("button[phx-value-name='pressure']") |> render_click()
    assert has_element?(view, "p[role=status]", "Pressure: 100044 Pa · committed generation 3")
  end

  test "structured analytics queries qualified buckets without inventing gaps", c do
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

    {:ok, view, html} = live(c.conn, Presenter.path(:asset, thing) <> "/analytics")
    assert html =~ "Workshop sensor analytics"
    assert has_element?(view, "#analytics-query")

    view |> form("#analytics-query") |> render_submit()
    assert has_element?(view, "h2", "Query result")
    assert render(view) =~ "24.3"
    assert render(view) =~ "1 qualified of"
    assert has_element?(view, "tbody tr")
    assert render(view) =~ "no line or value is inferred across a gap"
    assert has_element?(view, "svg[role=img]")
    assert has_element?(view, "path.chart-line")
    view |> element("button", "Export result JSON") |> render_click()
    assert_push_event(view, "download-query-result", %{"content" => analytics_json})
    analytics_export = Jason.decode!(analytics_json)
    assert {:ok, _} = QueryResult.from_map(analytics_export)
    assert analytics_export["qualified_rows"] == 1

    assert get_in(analytics_export, ["series", Access.at(0), "points", Access.at(0), "value"]) ==
             24.3

    assert has_element?(view, "[role=group][aria-label='Explore time window']")

    view |> element("button", "Later") |> render_click()
    shifted_from = DateTime.from_unix!(c.now - 43_199_999, :millisecond) |> DateTime.to_iso8601()
    assert has_element?(view, "#query-from[value='#{shifted_from}']")
    assert has_element?(view, "path.chart-line")

    view |> element("button", "Zoom out") |> render_click()
    assert has_element?(view, "path.chart-line")

    view |> form("#analytics-query", query: %{view: "area"}) |> render_submit()
    assert has_element?(view, "path.chart-area")

    view |> form("#analytics-query", query: %{view: "points"}) |> render_submit()
    assert has_element?(view, "circle.chart-point")
    refute has_element?(view, "path.chart-line")

    from_at = DateTime.from_unix!(c.now + 1, :millisecond) |> DateTime.to_iso8601()
    to_at = DateTime.from_unix!(c.now + 86_400_001, :millisecond) |> DateTime.to_iso8601()

    view
    |> form("#analytics-query", query: %{from: from_at, to: to_at})
    |> render_submit()

    assert render(view) =~ "No qualified readings in this window"
    refute has_element?(view, "tbody tr")
    refute has_element?(view, "svg[role=img]")
  end

  test "unsaved analytics follows committed state and retains a marked stale result", c do
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

    {:ok, view, _} = live(c.conn, Presenter.path(:asset, thing) <> "/analytics")
    view |> form("#analytics-query") |> render_submit()
    view |> element("button", "Start follow mode") |> render_click()
    assert render(view) =~ "Follow mode active"

    {:ok, imported} =
      Service.submit(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        import_request(%{id: "follow-state", observed_at: c.now + 1_000}, generation(c)),
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
          "observation_id" => imported["data"]["observation_id"],
          "owner_confirmed" => true,
          "expected_generation" => generation(c)
        },
        c.now
      )

    {:ok, _} =
      Service.materialize(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        %{"thing_id" => thing, "expected_generation" => generation(c)},
        c.now
      )

    Agent.update(c.faults, &Map.put(&1, :analytics, :unavailable))
    send(view.pid, {:follow, 1})
    assert render(view) =~ "displayed result is stale"
    assert render(view) =~ "24.3"

    send(view.pid, {:follow, 1})
    assert render(view) =~ "Follow mode active"
    refute render(view) =~ "displayed result is stale"

    shifted_to =
      DateTime.from_unix!(c.now + 1_001, :millisecond) |> DateTime.to_iso8601()

    assert has_element?(view, "#query-to[value='#{shifted_to}']")

    for fault <- [:unavailable, {:reply, {:ok, %{}}}] do
      Agent.update(c.faults, &Map.put(&1, :events, fault))
      send(view.pid, {:follow, 1})
      assert render(view) =~ "displayed result is stale"
      send(view.pid, {:follow, 1})
      assert render(view) =~ "Follow mode active"
    end

    Agent.update(
      c.faults,
      &Map.put(&1, :events, {:reply, {:error, %{"code" => "cursor_expired"}}})
    )

    Agent.update(c.faults, &Map.put(&1, :analytics, :unavailable))
    send(view.pid, {:follow, 1})
    assert render(view) =~ "displayed result is stale"
    send(view.pid, {:follow, 1})
    assert render(view) =~ "Follow mode active"

    # A quiet check does not execute the structured query again.
    Agent.update(c.faults, &Map.put(&1, :analytics, :unavailable))
    send(view.pid, {:follow, 1})
    assert render(view) =~ "Follow mode active"
    assert Agent.get(c.faults, &Map.get(&1, :analytics)) == :unavailable
    Agent.update(c.faults, &Map.delete(&1, :analytics))

    view |> element("button", "Earlier") |> render_click()
    assert has_element?(view, "button", "Start follow mode")
    refute has_element?(view, "button", "Stop follow mode")

    Agent.update(c.faults, &Map.put(&1, :analytics, :unavailable))
    send(view.pid, {:follow, 1})
    render(view)
    assert Agent.get(c.faults, &Map.get(&1, :analytics)) == :unavailable
  end

  test "unsaved analytics follow clears its result when current access disappears", c do
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

    {:ok, view, _} = live(c.conn, Presenter.path(:asset, thing) <> "/analytics")
    view |> form("#analytics-query") |> render_submit()
    view |> element("button", "Start follow mode") |> render_click()
    commit_change(c, "follow-revoked")
    Agent.update(c.faults, &Map.put(&1, :get, {:deny, "forbidden"}))
    send(view.pid, {:follow, 1})

    refute has_element?(view, "h2", "Query result")
    refute has_element?(view, "button", "Stop follow mode")
    assert has_element?(view, "[role=alert]")
  end

  test "unsaved analytics follow recovers when its initial cursor snapshot is unavailable", c do
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

    {:ok, view, _} = live(c.conn, Presenter.path(:asset, thing) <> "/analytics")
    view |> form("#analytics-query") |> render_submit()
    Agent.update(c.faults, &Map.put(&1, :list, :unavailable))
    view |> element("button", "Start follow mode") |> render_click()
    assert render(view) =~ "displayed result is stale"

    Agent.update(c.faults, &Map.put(&1, :list, {:reply, {:ok, %{}}}))
    send(view.pid, {:follow, 1})
    assert render(view) =~ "displayed result is stale"
    send(view.pid, {:follow, 1})
    assert render(view) =~ "Follow mode active"

    view |> element("button", "Stop follow mode") |> render_click()
    refute has_element?(view, "button", "Stop follow mode")
  end

  test "host operational pages require admin authority and retain a pinned collector page", c do
    cursor = %{
      "schema" => "wtr.operational-window-cursor.v1",
      "epoch" => "collector-one",
      "after" => 1,
      "through" => 2,
      "first" => 1,
      "event" => nil,
      "limit" => 25,
      "window_ms" => 300_000,
      "from_at" => c.now - 300_000,
      "to_at" => c.now
    }

    first = %{
      "schema" => "wtr.operational-window-page.v1",
      "epoch" => "collector-one",
      "captured_at" => c.now,
      "volatile" => true,
      "through" => 2,
      "samples" => [
        %{
          "sequence" => 1,
          "observed_at" => c.now,
          "event" => "query.stop",
          "measurements" => %{"duration_us" => 123, "scanned_rows" => 1},
          "metadata" => %{"aggregation" => "mean", "outcome" => "ok"}
        }
      ],
      "window" => %{
        "from_at" => c.now - 300_000,
        "to_at" => c.now,
        "duration_ms" => 300_000,
        "omitted_before" => 0,
        "samples" => [
          %{
            "sequence" => 1,
            "observed_at" => c.now,
            "event" => "query.stop",
            "measurements" => %{"duration_us" => 123, "scanned_rows" => 1},
            "metadata" => %{"aggregation" => "mean", "outcome" => "ok"}
          },
          %{
            "sequence" => 2,
            "observed_at" => c.now,
            "event" => "render.stop",
            "measurements" => %{"duration_us" => 456},
            "metadata" => %{"surface" => "browser", "outcome" => "ok"}
          }
        ]
      },
      "cursor" => cursor
    }

    second = %{
      first
      | "samples" => [
          %{
            "sequence" => 2,
            "observed_at" => c.now,
            "event" => "render.stop",
            "measurements" => %{"duration_us" => 456},
            "metadata" => %{"surface" => "browser", "outcome" => "ok"}
          }
        ],
        "cursor" => nil
    }

    Agent.update(c.faults, &Map.put(&1, :operational_history, {:page, first}))
    {:ok, view, html} = live(c.conn, "/operations")
    assert html =~ "Operational history"
    assert html =~ "query.stop"
    assert html =~ "duration_us: 123"
    assert has_element?(view, "#operational-window option[value='300000'][selected]")
    assert has_element?(view, "circle.chart-point")
    refute has_element?(view, "path.chart-line")
    assert has_element?(view, "button", "Next page")

    view
    |> form("#operational-metric", metric: %{name: "scanned_rows"})
    |> render_change()

    assert has_element?(view, "#metric-name option[value='scanned_rows'][selected]")
    assert has_element?(view, "circle.chart-point")

    Agent.update(c.faults, &Map.put(&1, :operational_history, {:page, second}))
    view |> element("button", "Next page") |> render_click()
    assert render(view) =~ "render.stop"
    refute render(view) =~ "No retained values for this measurement in this time window"
    assert has_element?(view, "circle.chart-point")
    assert has_element?(view, "button", "Previous page")

    Agent.update(c.faults, &Map.put(&1, :operational_history, {:page, first}))
    view |> element("button", "Previous page") |> render_click()
    assert render(view) =~ "query.stop"
    assert has_element?(view, "circle.chart-point")

    render_hook(view, "metric", %{"metric" => %{"name" => "invented"}})
    assert has_element?(view, "[role=alert]")
    assert has_element?(view, "circle.chart-point")

    Agent.update(c.faults, &Map.put(&1, :operational_history, :unavailable))
    view |> element("button", "Refresh") |> render_click()
    assert render(view) =~ "query.stop"
    assert has_element?(view, "[role=alert]")

    Agent.update(c.faults, &Map.put(&1, :operational_history, {:page, first}))

    filtered = %{
      first
      | "window" => %{
          first["window"]
          | "samples" => [hd(first["window"]["samples"])]
        },
        "cursor" => %{cursor | "event" => "query.stop"}
    }

    Agent.update(c.faults, &Map.put(&1, :operational_history, {:page, filtered}))

    view
    |> form("#operational-filter", filter: %{event: "query.stop", window_ms: "300000"})
    |> render_submit()

    assert has_element?(view, "#operational-event option[value='query.stop'][selected]")
    assert render(view) =~ "query.stop"

    Agent.update(c.faults, &Map.put(&1, :operational_history, {:page, %{"samples" => []}}))
    view |> element("button", "Refresh") |> render_click()
    refute has_element?(view, "tbody tr")
    assert has_element?(view, "[role=alert]")

    Agent.update(c.faults, &Map.put(&1, :operational_history, {:page, filtered}))
    view |> element("button", "Refresh") |> render_click()
    assert render(view) =~ "query.stop"

    render_hook(view, "filter", %{
      "filter" => %{"event" => "unknown", "window_ms" => "300000"}
    })

    assert has_element?(view, "[role=alert]")
    assert render(view) =~ "query.stop"

    Agent.update(c.faults, &Map.put(&1, :operational_history, {:deny, "forbidden"}))
    view |> element("button", "Refresh") |> render_click()
    refute has_element?(view, "tbody tr")
    assert has_element?(view, "[role=alert]")

    {:ok, %{"id" => reader}} = Sessions.login(c.sessions, c.reader, c.scope)
    conn = build_conn() |> init_test_session(%{"browser_session" => reader})
    {:ok, reader_view, _} = live(conn, "/operations")
    refute has_element?(reader_view, "#operational-filter")
    refute has_element?(reader_view, "tbody tr")
    assert has_element?(reader_view, "[role=alert]")
  end

  test "a prompted graph uses only disclosed schema and a newly authorized closed query", c do
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

    {:ok, view, _} = live(c.conn, Presenter.path(:asset, thing) <> "/analytics")
    assert has_element?(view, "#analytics-prompt")

    proposal = %{
      "kind" => "query",
      "measurement" => "temperature",
      "aggregation" => "mean",
      "quality" => "valid",
      "from" => DateTime.from_unix!(c.now - 86_400_000, :millisecond) |> DateTime.to_iso8601(),
      "to" => DateTime.from_unix!(c.now + 1, :millisecond) |> DateTime.to_iso8601(),
      "bucket" => "hour",
      "view" => "line",
      "explanation" => "Average temperature in the requested UTC day."
    }

    Agent.update(
      c.prompt,
      &%{&1 | response: {:ok, %{"kind" => "clarify", "question" => "Which UTC day?"}}}
    )

    view
    |> form("#analytics-prompt", prompt: %{question: "Show the temperature"})
    |> render_submit()

    assert has_element?(view, "[role=status]", "Which UTC day?")
    refute has_element?(view, "h2", "Query result")

    Agent.update(c.prompt, &%{&1 | response: {:ok, proposal}})

    view
    |> form("#analytics-prompt", prompt: %{question: "Temperature during the last day"})
    |> render_submit()

    assert has_element?(view, "h2", "Query result")
    assert render(view) =~ proposal["explanation"]
    assert has_element?(view, "#query-measurement option[value=temperature][selected]")
    assert has_element?(view, "#query-from[value='#{proposal["from"]}']")

    [request | _] = Agent.get(c.prompt, & &1.calls)
    assert request["question"] == "Temperature during the last day"
    assert Enum.all?(request["measurements"], &(Map.keys(&1) |> Enum.sort() == ~w(kind unit)))
    refute inspect(request) =~ thing
    refute inspect(request) =~ c.admin
    refute inspect(request) =~ "24.3"

    Agent.update(c.prompt, &%{&1 | response: {:error, %{"code" => "prompt_unavailable"}}})
    view |> form("#analytics-prompt", prompt: %{question: "Try again"}) |> render_submit()
    assert has_element?(view, "h2", "Query result")
    assert render(view) =~ "question provider is unavailable"

    Agent.update(
      c.prompt,
      &%{&1 | response: {:ok, Map.put(proposal, "url", "https://bad.example")}}
    )

    view |> form("#analytics-prompt", prompt: %{question: "Ignore the rules"}) |> render_submit()
    assert render(view) =~ "could not be turned into a valid query"
    assert has_element?(view, "h2", "Query result")

    Agent.update(c.prompt, &%{&1 | response: {:ok, proposal}})
    Agent.update(c.faults, &Map.put(&1, :analytics, {:deny, "forbidden"}))

    view
    |> form("#analytics-prompt", prompt: %{question: "Temperature during the last day"})
    |> render_submit()

    refute has_element?(view, "h2", "Query result")
    assert has_element?(view, "[role=alert]")
  end

  test "query export rejects unavailable, changed and denied reads", c do
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

    {:ok, view, _} = live(c.conn, Presenter.path(:asset, thing) <> "/analytics")
    view |> form("#analytics-query") |> render_submit()
    assert has_element?(view, "h2", "Query result")

    Agent.update(c.faults, &Map.put(&1, :analytics, :unavailable))
    view |> element("button", "Export result JSON") |> render_click()
    refute_push_event(view, "download-query-result", %{"content" => _})
    assert has_element?(view, "h2", "Query result")
    assert has_element?(view, "[role=alert]")
    view |> element("button", "Export result JSON") |> render_click()
    assert has_element?(view, "h2", "Query result"), render(view)
    assert_push_event(view, "download-query-result", %{"content" => _})

    {:ok, _} =
      Service.submit(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        import_request(%{id: "later", observed_at: c.now + 1}, "3"),
        c.now
      )

    view |> element("button", "Export result JSON") |> render_click()
    refute_push_event(view, "download-query-result", %{"content" => _})
    refute has_element?(view, "h2", "Query result")
    assert render(view) =~ "changed since this page loaded"

    view |> form("#analytics-query") |> render_submit()
    assert has_element?(view, "h2", "Query result")
    view |> element("button", "Start follow mode") |> render_click()
    assert has_element?(view, "button", "Stop follow mode")
    Agent.update(c.faults, &Map.put(&1, :analytics, {:deny, "forbidden"}))
    view |> element("button", "Export result JSON") |> render_click()
    refute_push_event(view, "download-query-result", %{"content" => _})
    refute has_element?(view, "h2", "Query result")
    refute has_element?(view, "button", "Stop follow mode")
    assert has_element?(view, "[role=alert]")
  end

  test "quality filters preserve exclusions, reject tampering and persist in a saved query", c do
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

    {:ok, view, _} = live(c.conn, Presenter.path(:asset, thing) <> "/analytics")
    assert has_element?(view, "#query-quality option[value='valid'][selected]")
    view |> form("#analytics-query", query: %{quality: "suspect"}) |> render_submit()
    assert render(view) =~ "0 qualified of 1 selected readings"
    assert render(view) =~ "1 excluded by quality"
    refute has_element?(view, "tbody tr")
    view |> element("button", "Export result JSON") |> render_click()
    assert_push_event(view, "download-query-result", %{"content" => suspect_json})
    assert Jason.decode!(suspect_json)["spec"]["qualities"] == ["suspect"]

    view |> form("#analytics-query", query: %{quality: "valid_suspect"}) |> render_submit()
    assert render(view) =~ "1 qualified of 1 selected readings"
    view |> element("button", "Prepare save") |> render_click()
    assert_patch(view)

    view
    |> form("#save-dashboard", save: %{title: "Both admitted qualities", window: "absolute"})
    |> render_submit()

    assert render(view) =~ "Dashboard saved"
    {:ok, page} = Service.list(c.service, c.admin, c.scope, "saved_queries", %{}, c.now)
    assert hd(page["items"])["value"]["query"]["qualities"] == ["valid", "suspect"]

    render_submit(view, "run", %{
      "query" => %{
        "measurement" => "temperature",
        "aggregation" => "mean",
        "quality" => "invalid",
        "from" => DateTime.from_unix!(c.now - 86_399_999, :millisecond) |> DateTime.to_iso8601(),
        "to" => DateTime.from_unix!(c.now + 1, :millisecond) |> DateTime.to_iso8601(),
        "bucket" => "hour",
        "view" => "line"
      }
    })

    assert has_element?(view, "[role=alert]")
    refute has_element?(view, "h2", "Query result")
  end

  test "analytics rejects tampered filters and reader sessions can query but not mutate", c do
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

    {:ok, %{"id" => reader}} = Sessions.login(c.sessions, c.reader, c.scope)
    conn = build_conn() |> init_test_session(%{"browser_session" => reader})
    {:ok, view, _} = live(conn, Presenter.path(:asset, thing) <> "/analytics")
    view |> form("#analytics-query") |> render_submit()
    assert has_element?(view, "h2", "Query result")

    render_submit(view, "run", %{
      "query" => %{
        "measurement" => "temperature; DROP TABLE records",
        "aggregation" => "mean",
        "from" => "2023-11-14T00:00:00Z",
        "to" => "2023-11-15T00:00:00Z",
        "bucket" => "hour",
        "view" => "line"
      }
    })

    assert has_element?(view, "[role=alert]")
    refute has_element?(view, "h2", "Query result")

    {:ok, _} =
      Service.revoke(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        %{"credential_id" => "reader", "expected_generation" => "3"},
        c.now
      )

    send(view.pid, :check_authority)
    assert_redirect(view, "/sign-in")
  end

  test "analytics explains unprovisioned and missing assets", c do
    {thing, _} = enrolled(c)
    {:ok, unprovisioned, html} = live(c.conn, Presenter.path(:asset, thing) <> "/analytics")
    assert html =~ "record measurements before querying history"
    refute has_element?(unprovisioned, "#analytics-query")
    refute has_element?(unprovisioned, "button", "Export result JSON")
    render_click(unprovisioned, "export-result", %{})
    assert has_element?(unprovisioned, "[role=alert]")
    render_submit(unprovisioned, "run", %{"query" => %{}})
    assert has_element?(unprovisioned, "[role=alert]")

    {:ok, missing, _} = live(c.conn, "/assets/missing/analytics")
    assert has_element?(missing, "[role=alert]")
    refute has_element?(missing, "#analytics-query")
  end

  test "analytics rejects invalid UTC bounds and reports a temporary query failure", c do
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

    {:ok, view, _} = live(c.conn, Presenter.path(:asset, thing) <> "/analytics")

    view
    |> form("#analytics-query", query: %{from: "2023-11-14T00:00:00+02:00"})
    |> render_submit()

    assert has_element?(view, "[role=alert]")
    refute has_element?(view, "h2", "Query result")

    from_at = DateTime.from_unix!(c.now - 3_600_000, :millisecond) |> DateTime.to_iso8601()
    to_at = DateTime.from_unix!(c.now + 1, :millisecond) |> DateTime.to_iso8601()

    render_submit(view, "run", %{
      "query" => %{
        "measurement" => "movementCounter",
        "aggregation" => "mean",
        "from" => from_at,
        "to" => to_at,
        "bucket" => "hour",
        "view" => "line"
      }
    })

    assert has_element?(view, "[role=alert]")
    refute has_element?(view, "h2", "Query result")

    Agent.update(c.faults, &Map.put(&1, :analytics, :unavailable))
    view |> element("button", "Refresh asset") |> render_click()
    view |> form("#analytics-query") |> render_submit()
    assert has_element?(view, "[role=alert]")
    refute has_element?(view, "h2", "Query result")
  end

  test "analytics time controls rerun bounded windows and keep gaps explicit", c do
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

    {:ok, view, _} = live(c.conn, Presenter.path(:asset, thing) <> "/analytics")
    view |> form("#analytics-query") |> render_submit()
    assert has_element?(view, "circle.chart-point")

    view |> element("button", "Earlier") |> render_click()
    assert render(view) =~ "No qualified readings in this window"
    refute has_element?(view, "circle.chart-point")

    view |> element("button", "Later") |> render_click()
    assert has_element?(view, "circle.chart-point")

    view |> element("button", "Zoom in") |> render_click()
    assert render(view) =~ "No qualified readings in this window"

    view |> element("button", "Zoom out") |> render_click()
    assert has_element?(view, "circle.chart-point")

    render_click(view, "navigate", %{"direction" => "unknown"})
    assert has_element?(view, "[role=alert]")
    assert has_element?(view, "circle.chart-point")
  end

  test "browser saves a rolling dashboard once and recovers its durable receipt", c do
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

    {:ok, view, _} = live(c.conn, Presenter.path(:asset, thing) <> "/analytics")
    view |> form("#analytics-query", query: %{view: "area"}) |> render_submit()
    assert has_element?(view, "button", "Prepare save")
    view |> element("button", "Prepare save") |> render_click()
    path = assert_patch(view)
    assert path =~ "?save_operation="
    assert has_element?(view, "#save-dashboard")

    view
    |> form("#save-dashboard", save: %{title: "Workshop temperature chart", window: "rolling"})
    |> render_submit()

    assert render(view) =~ "Dashboard saved"
    refute has_element?(view, "#save-dashboard")

    operation =
      path
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("save_operation")

    dashboard = "dashboard-" <> operation
    assert has_element?(view, "a[href='#{Presenter.dashboard_path(dashboard)}']")
    {:ok, saved} = Service.get(c.service, c.admin, c.scope, "saved_queries", dashboard, c.now)
    assert saved["value"]["title"] == "Workshop temperature chart"
    assert saved["value"]["visualization"]["type"] == "area"
    assert saved["value"]["window"]["kind"] == "rolling"

    {:ok, resumed, _} = live(c.conn, path)
    assert render(resumed) =~ "Dashboard saved"
    refute has_element?(resumed, "#save-dashboard")
    {:ok, page} = Service.list(c.service, c.admin, c.scope, "saved_queries", %{}, c.now)
    assert length(page["items"]) == 1
  end

  test "an incident snapshot saves the exact displayed result and refuses a superseded one", c do
    thing = provisioned(c)
    path = Presenter.path(:asset, thing) <> "/analytics"
    {:ok, view, _} = live(c.conn, path)
    view |> form("#analytics-query", query: %{view: "line"}) |> render_submit()
    commit_change(c, "before-snapshot")
    view |> element("button", "Prepare save") |> render_click()
    assert_patch(view)

    view
    |> form("#save-dashboard", save: %{title: "Superseded incident", window: "snapshot"})
    |> render_submit()

    assert has_element?(view, "[role=alert]", "service changed")

    assert {:ok, %{"items" => []}} =
             Service.list(c.service, c.admin, c.scope, "saved_queries", %{}, c.now)

    {:ok, fresh, _} = live(c.conn, path)
    fresh |> form("#analytics-query", query: %{view: "line"}) |> render_submit()
    fresh |> element("button", "Prepare save") |> render_click()
    patched = assert_patch(fresh)

    fresh
    |> form("#save-dashboard", save: %{title: "Workshop incident", window: "snapshot"})
    |> render_submit()

    assert render(fresh) =~ "Dashboard saved"
    dashboard = "dashboard-" <> URI.decode_query(URI.parse(patched).query)["save_operation"]

    {:ok, %{"value" => saved}} =
      Service.get(c.service, c.admin, c.scope, "saved_queries", dashboard, c.now)

    assert saved["schema"] == "wtr.saved-query.v3"

    assert %{"kind" => "snapshot", "generation" => "4", "result_identity" => identity} =
             saved["window"]

    commit_change(c, "after-snapshot")

    assert {:ok, %{"identity" => ^identity}} =
             Service.execute_saved_query(c.service, c.reader, c.scope, dashboard, c.now)

    {:ok, detail, _} = live(c.conn, Presenter.dashboard_path(dashboard))
    detail |> element("button", "Run saved query") |> render_click()
    assert has_element?(detail, "h2", "Query result")
  end

  test "read-only, stale and uncertain saves never create another dashboard", c do
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

    {:ok, %{"id" => reader}} = Sessions.login(c.sessions, c.reader, c.scope)
    conn = build_conn() |> init_test_session(%{"browser_session" => reader})
    {:ok, readonly, _} = live(conn, Presenter.path(:asset, thing) <> "/analytics")
    readonly |> form("#analytics-query") |> render_submit()
    refute has_element?(readonly, "button", "Prepare save")
    render_click(readonly, "prepare-save", %{})
    assert render(readonly) =~ "does not permit"

    {:ok, stale, _} = live(c.conn, Presenter.path(:asset, thing) <> "/analytics")
    stale |> form("#analytics-query") |> render_submit()
    stale |> element("button", "Prepare save") |> render_click()
    assert_patch(stale)

    {:ok, _} =
      Service.submit(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        import_request(%{id: "newer", observed_at: c.now + 1}, "3"),
        c.now
      )

    stale
    |> form("#save-dashboard", save: %{title: "Stale chart", window: "absolute"})
    |> render_submit()

    assert has_element?(stale, "[role=alert]")
    refute render(stale) =~ "Dashboard saved"
    {:ok, page} = Service.list(c.service, c.admin, c.scope, "saved_queries", %{}, c.now)
    assert page["items"] == []

    {:ok, uncertain, _} = live(c.conn, Presenter.path(:asset, thing) <> "/analytics")
    uncertain |> form("#analytics-query") |> render_submit()

    assert has_element?(uncertain, "h2", "Query result")

    uncertain |> element("button", "Prepare save") |> render_click()
    uncertain_path = assert_patch(uncertain)
    Agent.update(c.faults, &Map.put(&1, :save_query, :lost_reply))

    uncertain
    |> form("#save-dashboard", save: %{title: "Recovered chart", window: "absolute"})
    |> render_submit()

    assert render(uncertain) =~ "Save outcome unknown"
    refute has_element?(uncertain, "#save-dashboard")
    {:ok, recovered, _} = live(c.conn, uncertain_path)
    assert render(recovered) =~ "Dashboard saved"
    {:ok, page} = Service.list(c.service, c.admin, c.scope, "saved_queries", %{}, c.now)
    assert length(page["items"]) == 1
  end

  test "prepared save resumes after reconnect and recovers a lost verification read", c do
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

    path = Presenter.path(:asset, thing) <> "/analytics?save_operation=" <> Identifier.uuid()
    {:ok, view, _} = live(c.conn, path)
    refute has_element?(view, "#save-dashboard")
    view |> form("#analytics-query") |> render_submit()
    assert has_element?(view, "#save-dashboard")

    render_submit(view, "save", %{"save" => %{"title" => "", "window" => "absolute"}})
    assert has_element?(view, "[role=alert]")
    assert has_element?(view, "#save-dashboard")

    Agent.update(c.faults, &Map.put(&1, :get, :unavailable))

    view
    |> form("#save-dashboard", save: %{title: "Recovered fixed chart", window: "absolute"})
    |> render_submit()

    assert render(view) =~ "Save outcome unknown"
    refute has_element?(view, "#save-dashboard")
    view |> element("button", "Check save outcome") |> render_click()
    assert render(view) =~ "Dashboard saved"

    {:ok, resumed, _} = live(c.conn, path)
    assert render(resumed) =~ "Dashboard saved"
  end

  test "unrelated and invalid save references cannot authorize a dashboard mutation", c do
    {thing, enrollment_operation} = enrolled(c)

    {:ok, _} =
      Service.materialize(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        %{"thing_id" => thing, "expected_generation" => "2"},
        c.now
      )

    base = Presenter.path(:asset, thing) <> "/analytics"
    {:ok, invalid, _} = live(c.conn, base <> "?save_operation=invalid")
    assert has_element?(invalid, "[role=alert]")
    refute has_element?(invalid, "#save-dashboard")

    {:ok, unrelated, _} = live(c.conn, base <> "?save_operation=" <> enrollment_operation)
    assert render(unrelated) =~ "different workflow"
    unrelated |> form("#analytics-query") |> render_submit()
    refute has_element?(unrelated, "#save-dashboard")
    render_submit(unrelated, "save", %{"save" => %{"title" => "Wrong", "window" => "absolute"}})
    assert render(unrelated) =~ "different workflow"

    {:ok, retry, _} = live(c.conn, base)
    retry |> form("#analytics-query") |> render_submit()
    assert has_element?(retry, "h2", "Query result"), render(retry)
    Agent.update(c.faults, &Map.put(&1, :list, :unavailable))
    retry |> element("button", "Prepare save") |> render_click()
    assert has_element?(retry, "[role=alert]")
    refute has_element?(retry, "#save-dashboard")

    prepared = base <> "?save_operation=" <> Identifier.uuid()
    {:ok, interrupted, _} = live(c.conn, prepared)
    Agent.update(c.faults, &Map.put(&1, :list, :unavailable))
    interrupted |> form("#analytics-query") |> render_submit()
    assert has_element?(interrupted, "[role=alert]")
    refute has_element?(interrupted, "#save-dashboard")
    interrupted |> form("#analytics-query") |> render_submit()
    assert has_element?(interrupted, "#save-dashboard")
  end

  test "temporary save transport failure leaves the operation outcome unknown", c do
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

    {:ok, view, _} = live(c.conn, Presenter.path(:asset, thing) <> "/analytics")
    view |> form("#analytics-query") |> render_submit()
    view |> element("button", "Prepare save") |> render_click()
    assert_patch(view)
    Agent.update(c.faults, &Map.put(&1, :save_query, :unavailable))

    view
    |> form("#save-dashboard", save: %{title: "Temporary failure", window: "absolute"})
    |> render_submit()

    assert render(view) =~ "Save outcome unknown"
    refute has_element?(view, "#save-dashboard")
    view |> element("button", "Check save outcome") |> render_click()
    assert render(view) =~ "Save outcome unknown"
    {:ok, page} = Service.list(c.service, c.admin, c.scope, "saved_queries", %{}, c.now)
    assert page["items"] == []
  end

  test "saved dashboard lists and reruns an owned query under current reader access", c do
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

    query = dashboard_query(thing, c.now)
    dashboard = "workshop-temperature-dashboard"

    {:ok, _} =
      Service.save_query(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        %{
          "id" => dashboard,
          "title" => "Workshop temperature",
          "query" => query,
          "window" => %{"kind" => "rolling", "duration_ms" => query["to_at"] - query["from_at"]},
          "visualization" => %{"type" => "line", "show_legend" => true, "show_points" => true},
          "expected_generation" => "3"
        },
        c.now
      )

    {:ok, %{"id" => reader}} = Sessions.login(c.sessions, c.reader, c.scope)
    conn = build_conn() |> init_test_session(%{"browser_session" => reader})
    {:ok, index, _} = live(conn, "/dashboards")
    assert has_element?(index, "a[href='#{Presenter.dashboard_path(dashboard)}']")
    assert render(index) =~ "Rolling window"

    {:ok, detail, html} = live(conn, Presenter.dashboard_path(dashboard))
    assert html =~ "Workshop temperature"
    assert html =~ "Rolling"
    detail |> element("button", "Run saved query") |> render_click()
    assert has_element?(detail, "h2", "Query result")
    assert has_element?(detail, "path.chart-line")
    assert render(detail) =~ "24.3"
    assert render(detail) =~ "Snapshot"
    detail |> element("button", "Export result JSON") |> render_click()
    assert_push_event(detail, "download-query-result", %{"content" => dashboard_json})
    dashboard_export = Jason.decode!(dashboard_json)
    assert {:ok, _} = QueryResult.from_map(dashboard_export)
    assert dashboard_export["spec"]["series"] == [thing]

    assert get_in(dashboard_export, ["series", Access.at(0), "points", Access.at(0), "value"]) ==
             24.3

    detail |> element("button[phx-value-view='area']") |> render_click()
    assert has_element?(detail, "path.chart-area")
    assert has_element?(detail, "button[phx-value-view='area'][aria-pressed='true']")
    detail |> element("button[phx-value-view='table']") |> render_click()
    refute has_element?(detail, "svg[role=img]")
    assert has_element?(detail, "td", "24.3 °C")
    detail |> element("button[phx-value-view='points']") |> render_click()
    assert has_element?(detail, "circle.chart-point")
    refute has_element?(detail, "path.chart-line")
    assert render(detail) =~ dashboard_export["identity"]
    render_click(detail, "change-view", %{"view" => "raw"})
    assert has_element?(detail, "[role=alert]")
    assert has_element?(detail, "circle.chart-point")
    {:ok, unchanged} = Service.get(c.service, c.admin, c.scope, "saved_queries", dashboard, c.now)
    assert unchanged["value"]["visualization"]["type"] == "line"

    Agent.update(c.faults, &Map.put(&1, :get, {:deny, "forbidden"}))
    detail |> element("button", "Export result JSON") |> render_click()
    refute_push_event(detail, "download-query-result", %{"content" => _})
    refute has_element?(detail, "h2", "Query result")
    assert has_element?(detail, "[role=alert]")

    {:ok, history} =
      Service.history(c.service, c.admin, c.scope, "saved_queries", dashboard, %{}, c.now)

    assert length(history["items"]) == 1

    {:ok, _} =
      Service.revoke(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        %{"credential_id" => "reader", "expected_generation" => "4"},
        c.now
      )

    send(detail.pid, :check_authority)
    assert_redirect(detail, "/sign-in")
  end

  test "saved dashboard export rejects changed definitions and lost data authority", c do
    {dashboard, _} = saved_dashboard(c)
    path = Presenter.dashboard_path(dashboard)
    {:ok, detail, _} = live(c.conn, path)
    detail |> element("button", "Run saved query") |> render_click()
    assert has_element?(detail, "h2", "Query result")

    Agent.update(c.faults, &Map.put(&1, :get, :unavailable))
    detail |> element("button", "Export result JSON") |> render_click()
    refute_push_event(detail, "download-query-result", %{"content" => _})
    assert has_element?(detail, "h2", "Query result")
    detail |> element("button", "Export result JSON") |> render_click()
    assert has_element?(detail, "h2", "Query result"), render(detail)
    assert_push_event(detail, "download-query-result", %{"content" => _})

    {:ok, page} = Service.list(c.service, c.admin, c.scope, "saved_queries", %{}, c.now)

    {:ok, _} =
      Service.save_query(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        dashboard_request(dashboard, "Updated dashboard", c, page["generation"]),
        c.now
      )

    detail |> element("button", "Export result JSON") |> render_click()
    refute_push_event(detail, "download-query-result", %{"content" => _})
    refute has_element?(detail, "h2", "Query result")
    assert render(detail) =~ "changed since this page loaded"

    {:ok, current, _} = live(c.conn, path)
    current |> element("button", "Run saved query") |> render_click()

    assert has_element?(current, "h2", "Query result")

    Agent.update(c.faults, &Map.put(&1, :analytics, {:deny, "forbidden"}))
    current |> element("button", "Export result JSON") |> render_click()
    refute_push_event(current, "download-query-result", %{"content" => _})
    refute has_element?(current, "h2", "Query result")
    assert has_element?(current, "[role=alert]")
  end

  test "saved result window navigation leaves the stored dashboard unchanged", c do
    {dashboard, _} = saved_dashboard(c)

    {:ok, %{"value" => definition}} =
      Service.get(c.service, c.admin, c.scope, "saved_queries", dashboard, c.now)

    {:ok, original} =
      Service.execute_saved_query(c.service, c.admin, c.scope, dashboard, c.now)

    {:ok, view, _} = live(c.conn, Presenter.dashboard_path(dashboard))
    view |> element("button", "Run saved query") |> render_click()
    assert has_element?(view, "[aria-label='Explore saved result window']")

    view |> element("button", "Earlier") |> render_click()

    assert has_element?(view, "[role=status]", "Exploring")

    view |> element("button", "Export result JSON") |> render_click()
    assert_push_event(view, "download-query-result", %{"content" => json})
    navigated = Jason.decode!(json)
    assert navigated["spec"]["from_at"] < original["spec"]["from_at"]
    assert navigated["spec"]["to_at"] < original["spec"]["to_at"]
    assert navigated["snapshot"] == original["snapshot"]

    Agent.update(c.faults, &Map.put(&1, :analytics, :unavailable))
    view |> element("button", "Later") |> render_click()
    assert has_element?(view, "h2", "Query result")
    assert has_element?(view, "[role=alert]")
    assert has_element?(view, "[role=status]", "Exploring")

    render_click(view, "navigate-result", %{"direction" => "unknown"})
    assert has_element?(view, "h2", "Query result")
    view |> element("button", "Run saved query") |> render_click()
    refute has_element?(view, "[role=status]", "Exploring")

    assert {:ok, %{"value" => ^definition}} =
             Service.get(c.service, c.admin, c.scope, "saved_queries", dashboard, c.now)

    Agent.update(c.faults, &Map.put(&1, :analytics, {:deny, "forbidden"}))
    view |> element("button", "Earlier") |> render_click()
    refute has_element?(view, "h2", "Query result")
    assert has_element?(view, "[role=alert]")
  end

  test "an administrator saves two compatible series as a comparison dashboard", c do
    {first, second, _} = comparison_sources(c)
    {:ok, index, _} = live(c.conn, "/dashboards")
    assert has_element?(index, "a[href='/dashboards/compare']")
    operation = Identifier.uuid()
    path = "/dashboards/compare?operation=" <> operation
    {:ok, view, _} = live(c.conn, path)
    assert has_element?(view, "#compare-dashboard")

    view
    |> form("#compare-dashboard",
      compose: %{title: "Compare temperatures", query_ids: [first, second]}
    )
    |> render_submit()

    assert render(view) =~ "Comparison saved"
    refute has_element?(view, "#compare-dashboard")

    render_submit(view, "save", %{
      "compose" => %{"title" => "Repeated", "query_ids" => [first, second]}
    })

    refute has_element?(view, "#compare-dashboard")
    dashboard = "comparison-" <> operation
    assert has_element?(view, "a[href='#{Presenter.dashboard_path(dashboard)}']")
    {:ok, stored} = Service.get(c.service, c.admin, c.scope, "saved_queries", dashboard, c.now)
    assert stored["value"]["query"]["series"] == ["workshop-asset", "another-asset"]
    assert stored["value"]["visualization"]["type"] == "table"
    assert stored["value"]["window"]["kind"] == "rolling"

    {:ok, resumed, _} = live(c.conn, path)
    assert render(resumed) =~ "Comparison saved"
    {:ok, detail, _} = live(c.conn, Presenter.dashboard_path(dashboard))
    detail |> element("button", "Run saved query") |> render_click()
    assert has_element?(detail, "h3", "workshop-asset")
    assert has_element?(detail, "h3", "another-asset")
  end

  test "a saved multi-series graph shows a shared scale and leaves an empty series unplotted",
       c do
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

    {:ok, page} = Service.list(c.service, c.admin, c.scope, "saved_queries", %{}, c.now)
    id = "multi-series-graph"

    {:ok, _} =
      Service.save_query(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        dashboard_request(id, "Shared scale", c, page["generation"], [thing, "empty-asset"]),
        c.now
      )

    {:ok, detail, _} = live(c.conn, Presenter.dashboard_path(id))
    detail |> element("button", "Run saved query") |> render_click()
    assert has_element?(detail, "svg[aria-label*='comparing 2 series']")
    assert has_element?(detail, ".chart-series.series-1 path.chart-line")
    refute has_element?(detail, ".chart-series.series-2 circle")
    assert has_element?(detail, ".chart-legend li", thing)
    assert has_element?(detail, ".chart-legend li", "empty-asset")
    assert render(detail) =~ "No qualified readings in this series"
    assert has_element?(detail, "td", "24.3 °C")
    refute render(detail) =~ "No qualified readings in this window"

    detail |> element("button", "Prepare edit") |> render_click()
    assert_patch(detail)

    detail
    |> form("#edit-dashboard", edit: %{title: "Shared area", view: "area"})
    |> render_submit()

    detail |> element("button", "Run saved query") |> render_click()
    assert has_element?(detail, ".chart-series.series-1 path.chart-area")

    {:ok, newer} = Service.list(c.service, c.admin, c.scope, "saved_queries", %{}, c.now)

    table_request =
      dashboard_request(id, "Shared table", c, newer["generation"], [thing, "empty-asset"])
      |> update_in(["visualization", "type"], fn _ -> "table" end)

    {:ok, _} =
      Service.save_query(c.service, c.admin, c.scope, Identifier.uuid(), table_request, c.now)

    detail |> element("button", "Refresh definition") |> render_click()
    detail |> element("button", "Run saved query") |> render_click()
    refute has_element?(detail, "svg[role=img]")
    refute render(detail) =~ "No qualified readings in this window"
    assert has_element?(detail, "td", "24.3 °C")
  end

  test "a lost comparison reply recovers once and rejects a reused source operation", c do
    {first, second, source_operation} = comparison_sources(c)
    unrelated = "/dashboards/compare?operation=" <> source_operation
    {:ok, mismatch, _} = live(c.conn, unrelated)
    assert render(mismatch) =~ "different workflow"
    refute has_element?(mismatch, "#compare-dashboard")

    operation = Identifier.uuid()
    path = "/dashboards/compare?operation=" <> operation
    {:ok, view, _} = live(c.conn, path)
    Agent.update(c.faults, &Map.put(&1, :save_query, :lost_reply))

    view
    |> form("#compare-dashboard",
      compose: %{title: "Recovered comparison", query_ids: [first, second]}
    )
    |> render_submit()

    assert render(view) =~ "Save outcome unknown"
    refute has_element?(view, "#compare-dashboard")
    {:ok, resumed, _} = live(c.conn, path)
    assert render(resumed) =~ "Comparison saved"

    {:ok, history} =
      Service.history(
        c.service,
        c.admin,
        c.scope,
        "saved_queries",
        "comparison-" <> operation,
        %{},
        c.now
      )

    assert length(history["items"]) == 1
  end

  test "comparison recovers a failed verification read and leaves transport uncertainty explicit",
       c do
    {first, second, _} = comparison_sources(c)
    operation = Identifier.uuid()
    path = "/dashboards/compare?operation=" <> operation
    {:ok, view, _} = live(c.conn, path)
    Agent.update(c.faults, &Map.put(&1, :get, :unavailable))

    view
    |> form("#compare-dashboard", compose: %{title: "Verify later", query_ids: [first, second]})
    |> render_submit()

    assert render(view) =~ "Save outcome unknown"
    view |> element("button", "Check save outcome") |> render_click()
    assert render(view) =~ "Comparison saved"

    other_operation = Identifier.uuid()
    {:ok, uncertain, _} = live(c.conn, "/dashboards/compare?operation=" <> other_operation)
    Agent.update(c.faults, &Map.put(&1, :save_query, :unavailable))

    uncertain
    |> form("#compare-dashboard", compose: %{title: "No write", query_ids: [first, second]})
    |> render_submit()

    assert render(uncertain) =~ "Save outcome unknown"
    refute has_element?(uncertain, "#compare-dashboard")
    uncertain |> element("button", "Check save outcome") |> render_click()
    refute has_element?(uncertain, "#compare-dashboard")

    assert {:error, %{"code" => "not_found"}} =
             Service.get(
               c.service,
               c.admin,
               c.scope,
               "saved_queries",
               "comparison-" <> other_operation,
               c.now
             )
  end

  test "comparison rejects incompatible, repeated and unknown definitions", c do
    {first, second, _} = comparison_sources(c, :absolute_second)
    operation = Identifier.uuid()
    {:ok, view, _} = live(c.conn, "/dashboards/compare?operation=" <> operation)

    view
    |> form("#compare-dashboard",
      compose: %{title: "Different windows", query_ids: [first, second]}
    )
    |> render_submit()

    assert has_element?(view, "[role=alert]")
    assert has_element?(view, "#compare-dashboard")

    render_submit(view, "save", %{
      "compose" => %{"title" => "One series", "query_ids" => [first]}
    })

    assert has_element?(view, "[role=alert]")

    render_submit(view, "save", %{
      "compose" => %{"title" => "Repeated", "query_ids" => [first, first]}
    })

    assert has_element?(view, "[role=alert]")

    render_submit(view, "save", %{
      "compose" => %{"title" => "Missing", "query_ids" => [first, "missing"]}
    })

    assert has_element?(view, "[role=alert]")

    assert {:error, %{"code" => "not_found"}} =
             Service.get(
               c.service,
               c.admin,
               c.scope,
               "saved_queries",
               "comparison-" <> operation,
               c.now
             )
  end

  test "comparison requires distinct series even when definitions otherwise match", c do
    {first, _, _} = comparison_sources(c)
    duplicate = "duplicate-series-dashboard"
    {:ok, page} = Service.list(c.service, c.admin, c.scope, "saved_queries", %{}, c.now)

    {:ok, _} =
      Service.save_query(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        dashboard_request(duplicate, "Same asset", c, page["generation"]),
        c.now
      )

    {:ok, view, _} = live(c.conn, "/dashboards/compare?operation=" <> Identifier.uuid())

    view
    |> form("#compare-dashboard",
      compose: %{title: "Duplicate series", query_ids: [first, duplicate]}
    )
    |> render_submit()

    assert has_element?(view, "[role=alert]")
    assert has_element?(view, "#compare-dashboard")
  end

  test "comparison refuses a stale generation after a concurrent definition update", c do
    {first, second, _} = comparison_sources(c)
    operation = Identifier.uuid()
    {:ok, view, _} = live(c.conn, "/dashboards/compare?operation=" <> operation)
    {:ok, page} = Service.list(c.service, c.admin, c.scope, "saved_queries", %{}, c.now)

    {:ok, _} =
      Service.save_query(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        dashboard_request(first, "Newer source", c, page["generation"]),
        c.now
      )

    view
    |> form("#compare-dashboard", compose: %{title: "Stale", query_ids: [first, second]})
    |> render_submit()

    assert render(view) =~ "service changed since this page loaded"
    assert has_element?(view, "#compare-dashboard")

    assert {:error, %{"code" => "not_found"}} =
             Service.get(
               c.service,
               c.admin,
               c.scope,
               "saved_queries",
               "comparison-" <> operation,
               c.now
             )
  end

  test "comparison requires an administrator and a valid operation", c do
    {first, second, _} = comparison_sources(c)
    {:ok, %{"id" => reader}} = Sessions.login(c.sessions, c.reader, c.scope)
    conn = build_conn() |> init_test_session(%{"browser_session" => reader})
    {:ok, index, _} = live(conn, "/dashboards")
    refute has_element?(index, "a[href='/dashboards/compare']")
    {:ok, readonly, _} = live(conn, "/dashboards/compare?operation=" <> Identifier.uuid())
    refute has_element?(readonly, "#compare-dashboard")
    assert render(readonly) =~ "cannot save a comparison"

    render_submit(readonly, "save", %{
      "compose" => %{"title" => "Denied", "query_ids" => [first, second]}
    })

    assert render(readonly) =~ "does not permit"

    {:ok, invalid, _} = live(c.conn, "/dashboards/compare?operation=invalid")
    assert has_element?(invalid, "[role=alert]")
    refute has_element?(invalid, "#compare-dashboard")
    render_submit(invalid, "save", %{"compose" => %{}})
    assert has_element?(invalid, "[role=alert]")
    assert {:error, {:redirect, %{to: redirected}}} = live(c.conn, "/dashboards/compare")
    assert redirected =~ "/dashboards/compare?operation="
  end

  test "comparison reports a temporary list failure without saving", c do
    comparison_sources(c)
    {:ok, view, _} = live(c.conn, "/dashboards/compare?operation=" <> Identifier.uuid())
    Agent.update(c.faults, &Map.put(&1, :list, :unavailable))
    view |> element("button", "Refresh definitions") |> render_click()
    assert has_element?(view, "[role=alert]")
    refute has_element?(view, "#compare-dashboard")
    view |> element("button", "Refresh definitions") |> render_click()
    assert has_element?(view, "#compare-dashboard")
    refute has_element?(view, "[role=alert]")
  end

  test "an administrator edits a dashboard and reconnects without repeating the write", c do
    {dashboard, _} = saved_dashboard(c)
    path = Presenter.dashboard_path(dashboard)
    {:ok, detail, _} = live(c.conn, path)
    detail |> element("button", "Prepare edit") |> render_click()
    prepared = assert_patch(detail)
    assert has_element?(detail, "#edit-dashboard")

    detail
    |> form("#edit-dashboard", edit: %{title: "Updated workshop view", view: "area"})
    |> render_submit()

    assert render(detail) =~ "Dashboard updated"
    refute has_element?(detail, "#edit-dashboard")
    assert has_element?(detail, "h1", "Updated workshop view")
    {:ok, stored} = Service.get(c.service, c.admin, c.scope, "saved_queries", dashboard, c.now)
    assert stored["value"]["visualization"]["type"] == "area"
    assert stored["value"]["window"]["kind"] == "rolling"

    {:ok, resumed, _} = live(c.conn, prepared)
    assert render(resumed) =~ "Dashboard updated"
    refute has_element?(resumed, "#edit-dashboard")

    {:ok, history} =
      Service.history(c.service, c.admin, c.scope, "saved_queries", dashboard, %{}, c.now)

    assert length(history["items"]) == 2
  end

  test "a lost edit reply is recovered while readers cannot manage dashboards", c do
    {dashboard, _} = saved_dashboard(c)
    path = Presenter.dashboard_path(dashboard)
    {:ok, %{"id" => reader}} = Sessions.login(c.sessions, c.reader, c.scope)
    reader_conn = build_conn() |> init_test_session(%{"browser_session" => reader})
    {:ok, readonly, _} = live(reader_conn, path)
    refute has_element?(readonly, "button", "Prepare edit")
    render_click(readonly, "prepare-manage", %{"intent" => "delete"})
    assert render(readonly) =~ "does not permit"
    render_click(readonly, "delete", %{})
    assert {:ok, _} = Service.get(c.service, c.admin, c.scope, "saved_queries", dashboard, c.now)

    {:ok, detail, _} = live(c.conn, path)
    detail |> element("button", "Prepare edit") |> render_click()
    prepared = assert_patch(detail)
    Agent.update(c.faults, &Map.put(&1, :save_query, :lost_reply))

    detail
    |> form("#edit-dashboard", edit: %{title: "Recovered edit", view: "points"})
    |> render_submit()

    assert render(detail) =~ "Operation outcome unknown"
    refute has_element?(detail, "#edit-dashboard")
    {:ok, resumed, _} = live(c.conn, prepared)
    assert render(resumed) =~ "Dashboard updated"
    assert has_element?(resumed, "h1", "Recovered edit")

    {:ok, history} =
      Service.history(c.service, c.admin, c.scope, "saved_queries", dashboard, %{}, c.now)

    assert length(history["items"]) == 2
  end

  test "a lost delete reply recovers the tombstone without a second deletion", c do
    {dashboard, _} = saved_dashboard(c)
    {:ok, detail, _} = live(c.conn, Presenter.dashboard_path(dashboard))
    detail |> element("button", "Prepare delete") |> render_click()
    prepared = assert_patch(detail)
    assert has_element?(detail, "button", "Delete dashboard")
    Agent.update(c.faults, &Map.put(&1, :delete_query, :lost_reply))
    detail |> element("button", "Delete dashboard") |> render_click()
    assert render(detail) =~ "Operation outcome unknown"
    refute has_element?(detail, "button", "Delete dashboard")

    {:ok, resumed, _} = live(c.conn, prepared)
    assert render(resumed) =~ "Dashboard deleted"
    refute has_element?(resumed, "button", "Run saved query")

    assert {:error, %{"code" => "not_found"}} =
             Service.get(c.service, c.admin, c.scope, "saved_queries", dashboard, c.now)

    {:ok, history} =
      Service.history(c.service, c.admin, c.scope, "saved_queries", dashboard, %{}, c.now)

    assert length(history["items"]) == 2
  end

  test "stale and unrelated dashboard operations cannot overwrite or delete a definition", c do
    {dashboard, original_operation} = saved_dashboard(c)
    path = Presenter.dashboard_path(dashboard)
    {:ok, detail, _} = live(c.conn, path)
    detail |> element("button", "Prepare edit") |> render_click()
    assert_patch(detail)
    {:ok, page} = Service.list(c.service, c.admin, c.scope, "saved_queries", %{}, c.now)

    {:ok, _} =
      Service.save_query(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        dashboard_request(dashboard, "Other update", c, page["generation"]),
        c.now
      )

    detail
    |> form("#edit-dashboard", edit: %{title: "Stale update", view: "table"})
    |> render_submit()

    assert has_element?(detail, "[role=alert]")
    {:ok, stored} = Service.get(c.service, c.admin, c.scope, "saved_queries", dashboard, c.now)
    assert stored["value"]["title"] == "Other update"

    unrelated = path <> "?manage_operation=#{original_operation}&manage_intent=delete"
    {:ok, mismatch, _} = live(c.conn, unrelated)
    assert render(mismatch) =~ "different workflow"
    refute has_element?(mismatch, "button", "Delete dashboard")
    render_click(mismatch, "delete", %{})
    assert {:ok, _} = Service.get(c.service, c.admin, c.scope, "saved_queries", dashboard, c.now)

    {:ok, invalid, _} = live(c.conn, path <> "?manage_operation=invalid&manage_intent=edit")
    assert has_element?(invalid, "[role=alert]")
    refute has_element?(invalid, "#edit-dashboard")
    render_click(invalid, "prepare-manage", %{"intent" => "invalid"})
    refute has_element?(invalid, "#edit-dashboard")
  end

  test "a direct edit address can resume and preserve an absolute query", c do
    dashboard = "incident-dashboard"
    {:ok, page} = Service.list(c.service, c.admin, c.scope, "saved_queries", %{}, c.now)

    {:ok, _} =
      Service.save_query(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        dashboard_request(dashboard, "Incident view", c, page["generation"])
        |> Map.delete("window"),
        c.now
      )

    path =
      Presenter.dashboard_path(dashboard) <>
        "?manage_operation=#{Identifier.uuid()}&manage_intent=edit"

    {:ok, detail, _} = live(c.conn, path)
    assert has_element?(detail, "#edit-dashboard")
    render_submit(detail, "edit", %{"edit" => %{"title" => "Incident view", "view" => "invalid"}})
    assert has_element?(detail, "[role=alert]")

    detail
    |> form("#edit-dashboard", edit: %{title: "Incident table", view: "table"})
    |> render_submit()

    assert render(detail) =~ "Dashboard updated"
    {:ok, stored} = Service.get(c.service, c.admin, c.scope, "saved_queries", dashboard, c.now)
    assert stored["value"]["window"] == "absolute"
    assert stored["value"]["visualization"]["type"] == "table"
  end

  test "dashboard preparation and operation lookup failures cannot submit a mutation", c do
    {dashboard, _} = saved_dashboard(c)
    path = Presenter.dashboard_path(dashboard)
    {:ok, detail, _} = live(c.conn, path)
    Agent.update(c.faults, &Map.put(&1, :list, :unavailable))
    detail |> element("button", "Prepare edit") |> render_click()
    assert has_element?(detail, "[role=alert]")
    refute has_element?(detail, "#edit-dashboard")

    prepared = path <> "?manage_operation=#{Identifier.uuid()}&manage_intent=delete"
    {:ok, uncertain, _} = live(c.conn, prepared)
    assert has_element?(uncertain, "button", "Delete dashboard")
    Agent.update(c.faults, &Map.put(&1, :operation, :unavailable))
    uncertain |> element("button", "Check operation outcome") |> render_click()
    assert render(uncertain) =~ "Operation outcome unknown"
    refute has_element?(uncertain, "button", "Delete dashboard")
    uncertain |> element("button", "Check operation outcome") |> render_click()
    refute has_element?(uncertain, "button", "Delete dashboard")
    assert {:ok, _} = Service.get(c.service, c.admin, c.scope, "saved_queries", dashboard, c.now)
  end

  test "automatic dashboard refresh retains a marked stale result and recovers", c do
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

    {dashboard, _} = saved_dashboard(c, thing)
    {:ok, detail, _} = live(c.conn, Presenter.dashboard_path(dashboard))
    detail |> element("button", "Start auto-refresh") |> render_click()
    assert render(detail) =~ "Auto-refresh active"
    assert render(detail) =~ "24.3"
    assert has_element?(detail, "path.chart-line")
    detail |> element("button[phx-value-view='points']") |> render_click()
    assert has_element?(detail, "circle.chart-point")
    refute has_element?(detail, "path.chart-line")

    # A quiet check does not rerun the query.
    Agent.update(c.faults, &Map.put(&1, :execute_saved_query, :unavailable))
    send(detail.pid, {:auto_refresh, 1})
    assert render(detail) =~ "Auto-refresh active"
    assert Agent.get(c.faults, &Map.get(&1, :execute_saved_query)) == :unavailable

    commit_change(c, "follow-1")
    send(detail.pid, {:auto_refresh, 1})
    assert render(detail) =~ "displayed result is stale"
    assert render(detail) =~ "24.3"

    Agent.update(c.faults, &Map.put(&1, :get, :unavailable))
    send(detail.pid, {:auto_refresh, 1})
    assert render(detail) =~ "displayed result is stale"
    assert has_element?(detail, "circle.chart-point")

    # The unconsumed commit is retried on the next check.
    send(detail.pid, {:auto_refresh, 1})
    assert render(detail) =~ "Auto-refresh active"
    refute render(detail) =~ "displayed result is stale"
    assert has_element?(detail, "button[phx-value-view='points'][aria-pressed='true']")

    send(detail.pid, {:auto_refresh, 1})
    assert Agent.get(c.faults, &Map.has_key?(&1, :execute_saved_query)) == false
    Agent.update(c.faults, &Map.put(&1, :execute_saved_query, :unavailable))

    # A rolling window reruns after six quiet checks.
    for _ <- 1..4, do: send(detail.pid, {:auto_refresh, 1})
    assert render(detail) =~ "Auto-refresh active"
    send(detail.pid, {:auto_refresh, 1})
    assert render(detail) =~ "displayed result is stale"
    send(detail.pid, {:auto_refresh, 1})
    assert render(detail) =~ "Auto-refresh active"

    for fault <- [:unavailable, {:reply, {:ok, %{}}}] do
      Agent.update(c.faults, &Map.put(&1, :events, fault))
      send(detail.pid, {:auto_refresh, 1})
      assert render(detail) =~ "displayed result is stale"
      send(detail.pid, {:auto_refresh, 1})
      assert render(detail) =~ "Auto-refresh active"
    end

    Agent.update(
      c.faults,
      &Map.put(&1, :events, {:reply, {:error, %{"code" => "cursor_expired"}}})
    )

    Agent.update(c.faults, &Map.put(&1, :execute_saved_query, :unavailable))
    send(detail.pid, {:auto_refresh, 1})
    assert render(detail) =~ "displayed result is stale"
    send(detail.pid, {:auto_refresh, 1})
    assert render(detail) =~ "Auto-refresh active"

    for {fault, index} <- Enum.with_index([:unavailable, {:reply, {:ok, %{}}}]) do
      commit_change(c, "follow-list-#{index}")
      Agent.update(c.faults, &Map.put(&1, :list, fault))
      send(detail.pid, {:auto_refresh, 1})
      assert render(detail) =~ "displayed result is stale"
      send(detail.pid, {:auto_refresh, 1})
      assert render(detail) =~ "Auto-refresh active"
    end

    detail |> element("button", "Stop auto-refresh") |> render_click()
    assert has_element?(detail, "button", "Start auto-refresh")
    Agent.update(c.faults, &Map.put(&1, :execute_saved_query, :unavailable))
    send(detail.pid, {:auto_refresh, 1})
    render(detail)
    assert Agent.get(c.faults, &Map.get(&1, :execute_saved_query)) == :unavailable
  end

  test "automatic refresh reloads changed definitions and clears a deleted dashboard", c do
    {dashboard, _} = saved_dashboard(c)
    {:ok, detail, _} = live(c.conn, Presenter.dashboard_path(dashboard))
    detail |> element("button", "Start auto-refresh") |> render_click()
    {:ok, page} = Service.list(c.service, c.admin, c.scope, "saved_queries", %{}, c.now)

    {:ok, _} =
      Service.save_query(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        dashboard_request(dashboard, "Updated while following", c, page["generation"])
        |> put_in(["visualization", "type"], "area"),
        c.now
      )

    send(detail.pid, {:auto_refresh, 1})
    assert has_element?(detail, "h1", "Updated while following")
    assert has_element?(detail, "button[phx-value-view='area'][aria-pressed='true']")
    {:ok, current} = Service.list(c.service, c.admin, c.scope, "saved_queries", %{}, c.now)

    {:ok, _} =
      Service.delete_query(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        %{"id" => dashboard, "expected_generation" => current["generation"]},
        c.now
      )

    send(detail.pid, {:auto_refresh, 1})
    assert has_element?(detail, "[role=alert]")
    refute has_element?(detail, "button", "Run saved query")
    refute has_element?(detail, "button", "Stop auto-refresh")
  end

  test "automatic refresh clears a reader result when access is revoked", c do
    {dashboard, _} = saved_dashboard(c)
    {:ok, %{"id" => reader}} = Sessions.login(c.sessions, c.reader, c.scope)
    conn = build_conn() |> init_test_session(%{"browser_session" => reader})
    {:ok, detail, _} = live(conn, Presenter.dashboard_path(dashboard))
    detail |> element("button", "Start auto-refresh") |> render_click()
    assert has_element?(detail, "h2", "Query result")
    {:ok, page} = Service.list(c.service, c.admin, c.scope, "saved_queries", %{}, c.now)

    {:ok, _} =
      Service.revoke(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        %{"credential_id" => "reader", "expected_generation" => page["generation"]},
        c.now
      )

    send(detail.pid, {:auto_refresh, 1})
    refute has_element?(detail, "h2", "Query result")
    refute has_element?(detail, "button", "Stop auto-refresh")
    render_click(detail, "export-result", %{})
    assert_redirect(detail, "/sign-in")
  end

  test "missing and temporarily unavailable saved dashboards expose no result", c do
    {:ok, missing, _} = live(c.conn, "/dashboards/missing")
    assert has_element?(missing, "[role=alert]")
    refute has_element?(missing, "button", "Run saved query")
    refute has_element?(missing, "button", "Export result JSON")
    render_click(missing, "export-result", %{})
    assert has_element?(missing, "[role=alert]")
    render_click(missing, "run", %{})
    refute has_element?(missing, "h2", "Query result")

    {:ok, list, _} = live(c.conn, "/dashboards")
    assert render(list) =~ "No saved dashboards on this page"
    Agent.update(c.faults, &Map.put(&1, :list, :unavailable))
    list |> element("button", "Refresh") |> render_click()
    assert has_element?(list, "[role=alert]")
    assert has_element?(list, "[aria-label='Saved dashboards']")
  end

  test "saved dashboard list pages can be revisited at one generation", c do
    for index <- 0..25 do
      assert {:ok, _} =
               Service.save_query(
                 c.service,
                 c.admin,
                 c.scope,
                 Identifier.uuid(),
                 dashboard_request(
                   "page-dashboard-#{index}",
                   "Dashboard #{index}",
                   c,
                   Integer.to_string(index)
                 ),
                 c.now
               )
    end

    {:ok, list, _} = live(c.conn, "/dashboards")
    assert has_element?(list, "button", "Next page")
    refute has_element?(list, "button", "Previous page")
    list |> element("button", "Next page") |> render_click()
    assert has_element?(list, "button", "Previous page")
    refute has_element?(list, "button", "Next page")

    Agent.update(c.faults, &Map.put(&1, :list, :unavailable))
    list |> element("button", "Previous page") |> render_click()
    assert has_element?(list, "button", "Previous page")
    assert has_element?(list, "[role=alert]")
    list |> element("button", "Previous page") |> render_click()
    assert has_element?(list, "button", "Next page")
    refute has_element?(list, "button", "Previous page")

    list |> element("button", "Next page") |> render_click()

    assert {:ok, _} =
             Service.save_query(
               c.service,
               c.admin,
               c.scope,
               Identifier.uuid(),
               dashboard_request("page-dashboard-26", "Dashboard 26", c, "26"),
               c.now
             )

    list |> element("button", "Previous page") |> render_click()
    assert has_element?(list, "button", "Previous page")
    assert render(list) =~ "changed since this page loaded"
    list |> element("button", "Refresh") |> render_click()
    refute has_element?(list, "button", "Previous page")
    assert has_element?(list, "button", "Next page")

    list |> element("button", "Next page") |> render_click()
    Agent.update(c.faults, &Map.put(&1, :list, {:deny, "forbidden"}))
    list |> element("button", "Previous page") |> render_click()
    refute has_element?(list, "[aria-label='Saved dashboards']")
    assert has_element?(list, "[role=alert]")
  end

  test "protection lists committed rule status without private evidence", c do
    {:ok, view, html} = live(c.conn, "/protection")
    assert html =~ ~s(href="/protection")
    assert has_element?(view, "h2", "No rule status on this page")

    RuleFixtures.commit_all(c.store, c.scope)
    view |> element("button", "Refresh") |> render_click()

    for {kind, status} <- [
          {"Low battery", "Low"},
          {"Geofence", "Inside"},
          {"Reporting heartbeat", "Overdue"},
          {"Motion and trips", "Moving"},
          {"Transport health", "Degraded"}
        ] do
      assert has_element?(view, ".card", kind)
      assert has_element?(view, ".card .reading", status)
    end

    html = render(view)
    assert html =~ "Battery voltage: 2.5 V · available · quality: valid"
    assert html =~ "yard · revision yard-v1"
    assert html =~ "coordinate_inside"
    assert html =~ "unavailable · action: unavailable"
    assert html =~ "Started 2023-11-14 22:13:21 UTC"
    assert has_element?(view, ~s(a[href="/protection/heartbeat%3Asilence"]), "silence")

    for private <- ~w(capture private-hardware private-receiver latitude longitude bundle) do
      refute html =~ private
    end

    Agent.update(c.faults, &Map.put(&1, :list, :unavailable))
    view |> element("button", "Refresh") |> render_click()
    assert has_element?(view, ".card .reading", "Overdue")
    assert has_element?(view, "[role=alert]")

    Agent.update(c.faults, &Map.put(&1, :list, {:deny, "forbidden"}))
    view |> element("button", "Refresh") |> render_click()
    refute has_element?(view, ".card")
    assert has_element?(view, "[role=alert]")
  end

  test "protection list pages can be revisited at one generation", c do
    for index <- 10..35 do
      RuleFixtures.commit_heartbeat_versions(c.store, c.scope, "silence-#{index}", 1)
    end

    {:ok, list, _} = live(c.conn, "/protection")
    assert has_element?(list, "button", "Next page")
    refute has_element?(list, "button", "Previous page")
    list |> element("button", "Next page") |> render_click()
    assert has_element?(list, ".card h2", "silence-35")
    refute has_element?(list, "button", "Next page")

    Agent.update(c.faults, &Map.put(&1, :list, :unavailable))
    list |> element("button", "Previous page") |> render_click()
    assert has_element?(list, ".card h2", "silence-35")
    assert has_element?(list, "[role=alert]")
    list |> element("button", "Previous page") |> render_click()
    assert has_element?(list, ".card h2", "silence-10")
    refute has_element?(list, "button", "Previous page")

    list |> element("button", "Next page") |> render_click()
    RuleFixtures.commit_heartbeat_versions(c.store, c.scope, "silence-36", 1)
    list |> element("button", "Previous page") |> render_click()
    assert has_element?(list, ".card h2", "silence-35")
    assert render(list) =~ "changed since this page loaded"
    list |> element("button", "Refresh") |> render_click()
    refute has_element?(list, "button", "Previous page")

    list |> element("button", "Next page") |> render_click()
    Agent.update(c.faults, &Map.put(&1, :list, {:deny, "unauthorized"}))
    list |> element("button", "Previous page") |> render_click()
    refute has_element?(list, "[aria-label='Tracking rules']")
    assert has_element?(list, "[role=alert]")
  end

  test "rule detail pages retained evaluations under current authority", c do
    RuleFixtures.commit_heartbeat_versions(c.store, c.scope, "silence", 27)
    {:ok, rule, _} = live(c.conn, Presenter.rule_path("heartbeat:silence"))
    assert has_element?(rule, "h1", "silence")
    assert has_element?(rule, ".reading", "Reporting on time")
    assert render(rule) =~ "Maximum silence"
    assert has_element?(rule, "tbody tr:first-child td:first-child", "1")
    assert has_element?(rule, "tbody tr:nth-child(2) td:nth-child(2)", "Overdue")
    refute has_element?(rule, "button", "Previous history page")

    rule |> element("button", "Next history page") |> render_click()
    assert has_element?(rule, "tbody tr:first-child td:first-child", "26")
    refute has_element?(rule, "button", "Next history page")

    Agent.update(c.faults, &Map.put(&1, :history, :unavailable))
    rule |> element("button", "Previous history page") |> render_click()
    assert has_element?(rule, "tbody tr:first-child td:first-child", "26")
    assert has_element?(rule, "[role=alert]")
    rule |> element("button", "Previous history page") |> render_click()
    assert has_element?(rule, "tbody tr:first-child td:first-child", "1")

    Agent.update(c.faults, &Map.put(&1, :get, :unavailable))
    rule |> element("button", "Refresh") |> render_click()
    assert has_element?(rule, ".reading", "Reporting on time")
    assert has_element?(rule, "[role=alert]")

    Agent.update(c.faults, &Map.put(&1, :history, {:deny, "forbidden"}))
    rule |> element("button", "Next history page") |> render_click()
    refute has_element?(rule, ".reading")
    refute has_element?(rule, "table")
    assert has_element?(rule, "[role=alert]")

    {:ok, missing, _} = live(c.conn, Presenter.rule_path("heartbeat:missing"))
    assert has_element?(missing, "h1", "Rule status unavailable")
    assert render(missing) =~ "The requested record is not available."
  end

  test "an administrator adds an evaluated battery rule and reconnects to its receipt", c do
    thing = provisioned(c)

    {:ok, asset, _} =
      live(c.conn, Presenter.path(:asset, thing) <> "?operation=" <> Identifier.uuid())

    path = Presenter.path(:asset, thing) <> "/protection"
    assert has_element?(asset, ~s(a[href="#{path}"]), "Protection rules")

    {:ok, view, _} = live(c.conn, path)
    assert has_element?(view, "p", "No rules are defined for this asset.")
    refute has_element?(view, "#rule-definition")
    view |> element("button", "Prepare rule") |> render_click()
    patched = assert_patch(view)
    operation = operation_from(patched)

    view
    |> form("#rule-definition",
      rule: %{
        kind: "battery",
        low_threshold: "3.0",
        clear_threshold: "3.2",
        maximum_age_seconds: "86400",
        future_skew_seconds: "60",
        maximum_silence_seconds: "3600"
      }
    )
    |> render_submit()

    assert has_element?(view, "[role=status]", "Rule saved")
    rule_id = "battery:rule-" <> operation
    assert has_element?(view, ~s(a[href="#{Presenter.rule_path(rule_id)}"]), "Open rule status")
    assert has_element?(view, "caption", "1 of 8 rule definitions for this asset")
    assert has_element?(view, ~s(td a[href="#{Presenter.rule_path(rule_id)}"]), "Low battery")
    refute has_element?(view, "#rule-definition")

    assert {:ok, %{"value" => %{"status" => "low", "battery" => battery}}} =
             Service.get(c.service, c.reader, c.scope, "rules", rule_id, c.now)

    assert battery["low_threshold"] == %{"type" => "number", "value" => 3.0}
    assert battery["maximum_age_ms"] == %{"type" => "integer", "value" => 86_400_000}

    {:ok, resumed, _} = live(c.conn, patched)
    assert has_element?(resumed, "[role=status]", "Rule saved")
    refute has_element?(resumed, "#rule-definition")

    {:ok, status, _} = live(c.conn, Presenter.rule_path(rule_id))
    assert has_element?(status, ".reading", "Low")
  end

  test "an administrator adds closed motion and geofence definitions", c do
    thing = provisioned(c)
    path = Presenter.path(:asset, thing) <> "/protection"
    {:ok, motion_view, _} = live(c.conn, path)
    motion_view |> element("button", "Prepare rule") |> render_click()
    motion_path = assert_patch(motion_view)
    motion_operation = operation_from(motion_path)

    motion_view
    |> form("#rule-definition",
      rule: %{
        kind: "motion",
        event_time: "trusted_fix",
        future_skew_seconds: "1",
        late_window_seconds: "10",
        sequence: "none",
        uncertainty: "require_bound",
        moving_speed_m_s: "1.5",
        stationary_speed_m_s: "0.2",
        moving_distance_m: "5",
        stationary_distance_m: "1",
        max_plausible_speed_m_s: "100",
        max_gap_seconds: "300",
        minimum_movement_seconds: "30",
        minimum_stop_seconds: "60"
      }
    )
    |> render_submit()

    assert has_element?(motion_view, "[role=status]", "Rule saved")
    assert has_element?(motion_view, "td", "Motion and trips")
    assert render(motion_view) =~ "Moving ≥ 1.5 m/s · stationary ≤ 0.2 m/s"

    assert {:ok, %{"value" => motion}} =
             Service.get(
               c.service,
               c.reader,
               c.scope,
               "policies",
               "rule-" <> motion_operation,
               c.now
             )

    assert motion["parameters"]["minimum_movement_ms"] == 30_000
    assert motion["parameters"]["uncertainty"] == "require_bound"

    {:ok, fence_view, _} = live(c.conn, path)
    fence_view |> element("button", "Prepare rule") |> render_click()
    fence_path = assert_patch(fence_view)
    fence_operation = operation_from(fence_path)

    fence_view
    |> form("#rule-definition",
      rule: %{
        kind: "geofence",
        shape_kind: "circle",
        latitude: "59.3293",
        longitude: "18.0686",
        radius_m: "125",
        boundary: "inside",
        uncertainty: "coordinate_only",
        event_time: "trusted_fix_or_receiver",
        future_skew_seconds: "1",
        late_window_seconds: "10",
        sequence: "optional",
        max_transition_gap_seconds: "300"
      }
    )
    |> render_submit()

    assert has_element?(fence_view, "[role=status]", "Rule saved")
    assert has_element?(fence_view, "td", "Geofence")
    assert render(fence_view) =~ "Circle at 59.3293, 18.0686 · radius 125 m"

    assert {:ok, %{"value" => fence}} =
             Service.get(
               c.service,
               c.reader,
               c.scope,
               "policies",
               "rule-" <> fence_operation,
               c.now
             )

    assert fence["parameters"]["shape"]["radius_m"] == 125
    assert fence["parameters"]["event_time"] == "trusted_fix_or_receiver"
  end

  test "an administrator manages an event-only suspicious movement definition", c do
    thing = provisioned(c)
    asset_path = Presenter.path(:asset, thing) <> "/protection"
    {:ok, motion_view, _} = live(c.conn, asset_path)
    motion_view |> element("button", "Prepare rule") |> render_click()
    motion_operation = motion_view |> assert_patch() |> operation_from()
    refute has_element?(motion_view, ~s(input[value="suspicious_movement"]))

    motion_view
    |> form("#rule-definition",
      rule: %{
        kind: "motion",
        event_time: "trusted_fix",
        future_skew_seconds: "0",
        late_window_seconds: "10",
        sequence: "none",
        uncertainty: "require_bound",
        moving_speed_m_s: "1",
        stationary_speed_m_s: "0.1",
        moving_distance_m: "5",
        stationary_distance_m: "1",
        max_plausible_speed_m_s: "100",
        max_gap_seconds: "300",
        minimum_movement_seconds: "30",
        minimum_stop_seconds: "60"
      }
    )
    |> render_submit()

    motion_id = "rule-" <> motion_operation
    {:ok, suspicious_view, _} = live(c.conn, asset_path)
    suspicious_view |> element("button", "Prepare rule") |> render_click()
    suspicious_operation = suspicious_view |> assert_patch() |> operation_from()

    assert has_element?(
             suspicious_view,
             ~s(#rule-motion-binding option[value="#{motion_id}"])
           )

    suspicious_view
    |> form("#rule-definition",
      rule: %{
        kind: "suspicious_movement",
        motion_rule_id: motion_id,
        maximum_fact_age_seconds: "300",
        future_skew_seconds: "5"
      }
    )
    |> render_submit()

    suspicious_id = "rule-" <> suspicious_operation
    detail_path = Presenter.rule_path("suspicious_movement:" <> suspicious_id)
    assert has_element?(suspicious_view, "[role=status]", "Rule saved")
    assert has_element?(suspicious_view, ~s(a[href="#{detail_path}"]), "event-only definition")
    assert has_element?(suspicious_view, "td", "Event-only · alerts only")
    assert render(suspicious_view) =~ "Motion #{motion_id} · maximum fact age 300000 ms"

    assert {:error, %{"code" => "not_found"}} =
             Service.get(
               c.service,
               c.reader,
               c.scope,
               "rules",
               "suspicious_movement:" <> suspicious_id,
               c.now
             )

    assert {:ok, %{"value" => definition}} =
             Service.get(c.service, c.reader, c.scope, "policies", suspicious_id, c.now)

    assert definition["parameters"] == %{
             "motion_rule_id" => motion_id,
             "maximum_fact_age_ms" => 300_000,
             "future_skew_ms" => 5_000,
             "owner_unknown_as_absent" => false
           }

    refute Map.has_key?(definition, "policy")

    {:ok, detail, _} = live(c.conn, detail_path)
    assert has_element?(detail, "h1", suspicious_id)
    assert render(detail) =~ "has no current rule status or evaluation history"
    refute has_element?(detail, ".reading")
    refute has_element?(detail, "#rule-history-title")
    assert has_element?(detail, "button", "Prepare edit")

    detail |> element("button", "Prepare edit") |> render_click()
    assert_patch(detail)
    assert has_element?(detail, ~s(#rule-motion-binding option[value="#{motion_id}"][selected]))

    detail
    |> form("#edit-rule", rule: %{maximum_fact_age_seconds: "600"})
    |> render_submit()

    assert has_element?(detail, "[role=status]", "Rule definition updated")

    assert {:ok, %{"value" => revised}} =
             Service.get(c.service, c.reader, c.scope, "policies", suspicious_id, c.now)

    assert revised["parameters"]["maximum_fact_age_ms"] == 600_000
    refute Map.has_key?(revised, "policy")

    assert {:ok, _} =
             Service.delete_policy(
               c.service,
               c.admin,
               c.scope,
               Identifier.uuid(),
               %{"id" => motion_id, "expected_generation" => revised["revision"]},
               c.now
             )

    {:ok, unbound, _} = live(c.conn, detail_path)
    assert render(unbound) =~ "Add a motion definition for this asset before rebinding"
    refute has_element?(unbound, "button", "Prepare edit")
    assert has_element?(unbound, "button", "Prepare delete")

    {:ok, delete, _} = live(c.conn, detail_path)
    delete |> element("button", "Prepare delete") |> render_click()
    delete_path = assert_patch(delete)
    delete |> element("button", "Delete rule definition") |> render_click()
    assert has_element?(delete, "[role=status]", "Rule definition deleted")

    {:ok, resumed, _} = live(c.conn, delete_path)
    assert has_element?(resumed, "[role=status]", "Rule definition deleted")
    refute has_element?(resumed, "#rule-definition-title")
  end

  test "an administrator explicitly arms and disarms an asset with operation recovery", c do
    thing = provisioned(c)
    path = Presenter.arming_path(thing)

    {:ok, unavailable, _} = live(c.conn, path)
    assert has_element?(unavailable, ".reading", "Unknown")
    assert has_element?(unavailable, "h2", "Motion rule required")
    refute has_element?(unavailable, "button", "Prepare arm")

    assert {:ok, %{"generation" => "4"}} =
             Service.save_policy(
               c.service,
               c.admin,
               c.scope,
               Identifier.uuid(),
               motion_rule(thing, "3"),
               c.now
             )

    {:ok, protection, _} = live(c.conn, Presenter.path(:asset, thing) <> "/protection")
    assert has_element?(protection, ~s(a[href="#{path}"]), "Review arming state")

    {:ok, view, _} = live(c.conn, path)
    assert has_element?(view, ".reading", "Unknown")
    assert render(view) =~ "Unknown is not treated as disarmed"

    view |> element("button", "Prepare arm") |> render_click()
    armed_path = assert_patch(view)
    assert URI.decode_query(URI.parse(armed_path).query)["status"] == "armed"
    assert has_element?(view, "#arming-confirmation")

    render_submit(view, "commit", %{})
    assert has_element?(view, "[role=alert]", "Check the required fields")

    Agent.update(c.faults, &Map.put(&1, :set_arming, :lost_reply))

    view
    |> form("#arming-confirmation", arming: %{confirmed: "yes"})
    |> render_submit()

    assert has_element?(view, "[role=status]", "Arming outcome unknown")
    assert has_element?(view, ".identifier", operation_from(armed_path))

    view |> element("button", "Check operation outcome") |> render_click()
    assert has_element?(view, "[role=status]", "Service state committed: Armed")
    assert has_element?(view, ".reading", "Armed")
    assert render(view) =~ "does not contact the tracker"

    assert {:ok, %{"value" => %{"status" => "armed", "revision" => "arming-5"}}} =
             Service.get(c.service, c.reader, c.scope, "arming", thing, c.now)

    {:ok, overview, _} = live(c.conn, "/")
    assert has_element?(overview, ".asset-summary strong", "Armed")
    assert has_element?(overview, ".asset-summary a", "Review")

    {:ok, resumed, _} = live(c.conn, armed_path)
    assert has_element?(resumed, "[role=status]", "Service state committed: Armed")
    assert has_element?(resumed, ".reading", "Armed")

    {:ok, disarm, _} = live(c.conn, path)
    disarm |> element("button", "Prepare disarm") |> render_click()
    disarmed_path = assert_patch(disarm)
    assert URI.decode_query(URI.parse(disarmed_path).query)["status"] == "disarmed"

    disarm
    |> form("#arming-confirmation", arming: %{confirmed: "yes"})
    |> render_submit()

    assert has_element?(disarm, "[role=status]", "Service state committed: Disarmed")
    assert has_element?(disarm, ".reading", "Disarmed")

    assert {:ok, %{"value" => %{"status" => "disarmed", "revision" => "arming-6"}}} =
             Service.get(c.service, c.reader, c.scope, "arming", thing, c.now)

    {:ok, activity, _} = live(c.conn, "/activity")
    assert has_element?(activity, ~s(a[href="#{path}"]), "Disarmed asset")
  end

  test "the arming screen presents reviewed owner presence without inferring absence", c do
    thing = provisioned(c)

    assert {:ok, %{"generation" => "4"}} =
             Service.save_policy(
               c.service,
               c.admin,
               c.scope,
               Identifier.uuid(),
               motion_rule(thing, "3"),
               c.now
             )

    path = Presenter.arming_path(thing)
    {:ok, view, _} = live(c.conn, path)
    assert has_element?(view, "#owner-presence-title", "Owner-presence evidence")
    assert render(view) =~ "radio silence remain"
    assert has_element?(view, "#owner-presence-title + .reading", "Unknown")

    absent = owner_presence_fact(thing, "absent", "false", c.now)

    assert {:ok, %{"generation" => "5"}} =
             Service.admit_owner_presence(
               c.service,
               c.admin,
               c.scope,
               Identifier.uuid(),
               %{"thing_id" => thing, "fact" => absent, "expected_generation" => "4"},
               c.now + 1
             )

    view |> element("button", "Refresh") |> render_click()
    assert has_element?(view, "#owner-presence-title + .reading", "Absent")
    assert render(view) =~ "revision owner-presence-5"
    assert render(view) =~ "cannot create or edit presence evidence"

    for private <- ~w(presence-observation-ui presence-evidence-ui owner.present) do
      refute render(view) =~ private
    end

    Agent.update(c.faults, &Map.put(&1, :owner_presence, :unavailable))
    view |> element("button", "Refresh") |> render_click()
    assert has_element?(view, "#owner-presence-title + .reading", "Absent")
    assert has_element?(view, "[role=alert]")

    Agent.update(c.faults, &Map.put(&1, :owner_presence, {:deny, "forbidden"}))
    view |> element("button", "Refresh") |> render_click()
    assert has_element?(view, "#owner-presence-title + .reading", "Unknown")
    assert has_element?(view, "[role=alert]")

    Agent.update(c.faults, &Map.put(&1, :owner_presence, {:reply, {:ok, %{}}}))
    view |> element("button", "Refresh") |> render_click()
    assert has_element?(view, "#owner-presence-title + .reading", "Unknown")
    assert has_element?(view, "[role=alert]")

    assert {:ok, %{"value" => public_presence}} =
             Service.get(c.service, c.reader, c.scope, "owner_presence", thing, c.now + 1)

    Agent.update(
      c.faults,
      &Map.put(
        &1,
        :owner_presence,
        {:reply, {:ok, %{"value" => Map.put(public_presence, "private", true)}}}
      )
    )

    view |> element("button", "Refresh") |> render_click()
    assert has_element?(view, "#owner-presence-title + .reading", "Unknown")
    assert has_element?(view, "[role=alert]")

    for revision <- [nil, "owner-presence-x"] do
      invalid = Map.put(public_presence, "revision", revision)

      Agent.update(
        c.faults,
        &Map.put(&1, :owner_presence, {:reply, {:ok, %{"value" => invalid}}})
      )

      view |> element("button", "Refresh") |> render_click()
      assert has_element?(view, "#owner-presence-title + .reading", "Unknown")
    end

    view |> element("button", "Refresh") |> render_click()
    assert has_element?(view, "#owner-presence-title + .reading", "Absent")

    present = owner_presence_fact(thing, "present", "true", c.now + 2)

    assert {:ok, %{"generation" => "6"}} =
             Service.admit_owner_presence(
               c.service,
               c.admin,
               c.scope,
               Identifier.uuid(),
               %{"thing_id" => thing, "fact" => present, "expected_generation" => "5"},
               c.now + 3
             )

    view |> element("button", "Refresh") |> render_click()
    assert has_element?(view, "#owner-presence-title + .reading", "Present")

    unknown = owner_presence_fact(thing, "unknown", "unknown", c.now + 4)

    assert {:ok, %{"generation" => "7"}} =
             Service.admit_owner_presence(
               c.service,
               c.admin,
               c.scope,
               Identifier.uuid(),
               %{"thing_id" => thing, "fact" => unknown, "expected_generation" => "6"},
               c.now + 5
             )

    view |> element("button", "Refresh") |> render_click()
    assert has_element?(view, "#owner-presence-title + .reading", "Unknown")
  end

  test "arming controls fail closed for readers, stale pages and malformed state", c do
    thing = provisioned(c)

    assert {:ok, %{"generation" => "4"}} =
             Service.save_policy(
               c.service,
               c.admin,
               c.scope,
               Identifier.uuid(),
               motion_rule(thing, "3"),
               c.now
             )

    assert {:ok, %{"generation" => "5"}} =
             Service.set_arming(
               c.service,
               c.admin,
               c.scope,
               Identifier.uuid(),
               %{"thing_id" => thing, "status" => "armed", "expected_generation" => "4"},
               c.now
             )

    {:ok, %{"id" => reader}} = Sessions.login(c.sessions, c.reader, c.scope)
    reader_conn = build_conn() |> init_test_session(%{"browser_session" => reader})
    {:ok, reader_view, _} = live(reader_conn, Presenter.arming_path(thing))
    assert has_element?(reader_view, ".reading", "Armed")
    assert render(reader_view) =~ "cannot arm or disarm"
    refute has_element?(reader_view, "button", "Prepare arm")

    {:ok, view, _} = live(c.conn, Presenter.arming_path(thing))
    Agent.update(c.faults, &Map.put(&1, :arming, :unavailable))
    view |> element("button", "Refresh") |> render_click()
    assert has_element?(view, ".reading", "Armed")
    assert has_element?(view, "[role=alert]")

    {:ok, %{"value" => arming}} =
      Service.get(c.service, c.reader, c.scope, "arming", thing, c.now)

    Agent.update(
      c.faults,
      &Map.put(&1, :arming, {:reply, {:ok, %{"value" => Map.put(arming, "private", true)}}})
    )

    view |> element("button", "Refresh") |> render_click()
    assert has_element?(view, ".reading", "Unknown")
    assert has_element?(view, "[role=alert]")

    view |> element("button", "Refresh") |> render_click()
    assert has_element?(view, ".reading", "Armed")

    view |> element("button", "Prepare disarm") |> render_click()
    commit_change(c, "arming-conflict")

    view
    |> form("#arming-confirmation", arming: %{confirmed: "yes"})
    |> render_submit()

    assert has_element?(view, "[role=alert]", "service changed")

    assert {:ok, %{"value" => %{"status" => "armed"}}} =
             Service.get(c.service, c.reader, c.scope, "arming", thing, c.now)

    {:ok, invalid, _} =
      live(c.conn, Presenter.arming_path(thing) <> "?operation=bad&status=armed")

    assert has_element?(invalid, "[role=alert]", "Check the required fields")
    refute has_element?(invalid, "#arming-confirmation")
  end

  test "arming workflow preserves unknown outcomes across malformed and failed boundaries", c do
    thing = provisioned(c)
    path = Presenter.arming_path(thing)

    assert {:ok, %{"generation" => "4"}} =
             Service.save_policy(
               c.service,
               c.admin,
               c.scope,
               Identifier.uuid(),
               motion_rule(thing, "3"),
               c.now
             )

    {:ok, boundary, _} = live(c.conn, path)

    Agent.update(c.faults, &Map.put(&1, :get, :unavailable))
    render_click(boundary, "refresh", %{})
    assert has_element?(boundary, "[role=alert]")
    render_click(boundary, "refresh", %{})

    Agent.update(c.faults, &Map.put(&1, :thing_policies, {:reply, {:ok, %{}}}))
    render_click(boundary, "refresh", %{})
    assert has_element?(boundary, "[role=alert]")
    render_click(boundary, "refresh", %{})

    for fault <- [
          {:deny, "forbidden"},
          {:reply, {:ok, %{}}}
        ] do
      Agent.update(c.faults, &Map.put(&1, :arming, fault))
      render_click(boundary, "refresh", %{})
      assert has_element?(boundary, "[role=alert]")
    end

    render_click(boundary, "refresh", %{})
    render_click(boundary, "prepare", %{"status" => "invalid"})
    assert has_element?(boundary, "[role=alert]")
    assert render_click(boundary, "unknown-event", %{}) =~ "Change arming state"

    for fault <- [:unavailable, {:reply, {:ok, %{}}}] do
      {:ok, failed_prepare, _} = live(c.conn, path)
      Agent.update(c.faults, &Map.put(&1, :list, fault))
      render_click(failed_prepare, "prepare", %{"status" => "armed"})
      assert has_element?(failed_prepare, "[role=alert]")
    end

    operation = Identifier.uuid()
    {:ok, failed_resume, _} = live(c.conn, path)
    Agent.update(c.faults, &Map.put(&1, :list, :unavailable))
    render_patch(failed_resume, path <> "?operation=#{operation}&status=armed")
    assert has_element?(failed_resume, "[role=alert]")

    {:ok, invalid_revision, _} = live(c.conn, path)

    Agent.update(
      c.faults,
      &Map.put(&1, :arming, {:reply, {:ok, invalid_arming(thing, "arming-x")}})
    )

    render_click(invalid_revision, "refresh", %{})
    assert has_element?(invalid_revision, ".reading", "Unknown")

    {:ok, invalid_prefix, _} = live(c.conn, path)
    Agent.update(c.faults, &Map.put(&1, :arming, {:reply, {:ok, invalid_arming(thing, "bad")}}))
    render_click(invalid_prefix, "refresh", %{})
    assert has_element?(invalid_prefix, ".reading", "Unknown")

    {:ok, unrelated_receipt, _} = prepared_arming_view(c, path)

    Agent.update(
      c.faults,
      &Map.put(
        &1,
        :set_arming,
        {:reply,
         {:ok,
          %{
            "outcome" => "committed",
            "data" => %{"thing_id" => thing, "status" => "disarmed"}
          }}}
      )
    )

    confirm_arming(unrelated_receipt)
    assert has_element?(unrelated_receipt, "[role=status]", "Arming outcome unknown")

    {:ok, malformed_receipt, _} = prepared_arming_view(c, path)
    Agent.update(c.faults, &Map.put(&1, :set_arming, {:reply, {:ok, %{"outcome" => "other"}}}))
    confirm_arming(malformed_receipt)
    assert has_element?(malformed_receipt, "[role=status]", "Arming outcome unknown")

    {:ok, failed_commit, _} = prepared_arming_view(c, path)
    Agent.update(c.faults, &Map.put(&1, :set_arming, :unavailable))
    confirm_arming(failed_commit)
    assert has_element?(failed_commit, "[role=status]", "Arming outcome unknown")

    {:ok, failed_verify, failed_verify_path} = prepared_arming_view(c, path)
    operation = operation_from(failed_verify_path)

    Agent.update(c.faults, fn faults ->
      faults
      |> Map.put(
        :set_arming,
        {:reply,
         {:ok,
          %{
            "outcome" => "committed",
            "operation_id" => operation,
            "data" => %{"thing_id" => thing, "status" => "armed"}
          }}}
      )
      |> Map.put(:arming, :unavailable)
    end)

    confirm_arming(failed_verify)
    assert has_element?(failed_verify, "[role=status]", "Arming outcome unknown")
  end

  test "an asset's protection page lists its rule definitions up to the limit", c do
    thing = provisioned(c)
    path = Presenter.path(:asset, thing) <> "/protection"

    battery = %{
      "id" => "low-battery",
      "kind" => "battery",
      "thing_id" => thing,
      "parameters" => %{
        "measurement_kind" => "batteryVoltage",
        "unit" => "V",
        "low_threshold" => 3.0,
        "clear_threshold" => 3.2,
        "maximum_age_ms" => 86_400_000,
        "future_skew_ms" => 60_000,
        "accept_suspect" => false
      },
      "expected_generation" => "3"
    }

    heartbeat = %{
      "id" => "silence-1",
      "kind" => "heartbeat",
      "thing_id" => thing,
      "parameters" => %{"maximum_silence_ms" => 3_600_500, "future_skew_ms" => 0},
      "expected_generation" => "4"
    }

    {:ok, _} = Service.save_policy(c.service, c.admin, c.scope, Identifier.uuid(), battery, c.now)

    {:ok, %{"generation" => generation}} =
      Service.save_policy(c.service, c.admin, c.scope, Identifier.uuid(), heartbeat, c.now)

    {:ok, view, _} = live(c.conn, path)
    assert has_element?(view, "caption", "2 of 8 rule definitions for this asset")

    assert has_element?(
             view,
             ~s(td a[href="#{Presenter.rule_path("battery:low-battery")}"]),
             "Low battery"
           )

    assert has_element?(
             view,
             ~s(td a[href="#{Presenter.rule_path("heartbeat:silence-1")}"]),
             "Reporting heartbeat"
           )

    html = render(view)

    assert html =~
             "Low at or below 3.0 V · clears at or above 3.2 V · maximum reading age 86400000 ms"

    assert html =~ "Maximum silence 3600500 ms"
    assert has_element?(view, "td", ~r/^\s*Low\s*$/)
    assert has_element?(view, "td", ~r/^\s*Reporting on time\s*$/)
    assert has_element?(view, "button", "Prepare rule")
    assert Presenter.rule_parameters("motion", %{}) == "Parameters unavailable"

    {:ok, %{"id" => reader}} = Sessions.login(c.sessions, c.reader, c.scope)
    reader_conn = build_conn() |> init_test_session(%{"browser_session" => reader})

    {:ok, reader_asset, _} =
      live(reader_conn, Presenter.path(:asset, thing) <> "?operation=" <> Identifier.uuid())

    assert has_element?(reader_asset, ~s(a[href="#{path}"]), "Protection rules")
    {:ok, reader_view, _} = live(reader_conn, path)
    assert has_element?(reader_view, "caption", "2 of 8 rule definitions for this asset")
    assert render(reader_view) =~ "cannot add rules"
    refute has_element?(reader_view, "button", "Prepare rule")

    Agent.update(c.faults, &Map.put(&1, :thing_rules, :unavailable))
    view |> element("button", "Refresh") |> render_click()
    assert has_element?(view, "td", ~r/^\s*Unavailable\s*$/)
    assert has_element?(view, "caption", "2 of 8 rule definitions for this asset")

    Agent.update(c.faults, &Map.put(&1, :thing_policies, :unavailable))
    view |> element("button", "Refresh") |> render_click()
    assert has_element?(view, "[role=status]", "Defined rules are unavailable")
    refute has_element?(view, "caption")
    refute has_element?(view, "button", "Prepare rule")
    render_click(view, "prepare", %{})
    refute has_element?(view, "#rule-definition")
    view |> element("button", "Refresh") |> render_click()
    assert has_element?(view, "caption", "2 of 8 rule definitions for this asset")
    refute has_element?(view, "[role=alert]")

    Enum.reduce(2..7, generation, fn index, current ->
      request = %{heartbeat | "id" => "silence-#{index}", "expected_generation" => current}

      {:ok, %{"generation" => next}} =
        Service.save_policy(c.service, c.admin, c.scope, Identifier.uuid(), request, c.now)

      next
    end)

    view |> element("button", "Refresh") |> render_click()
    assert has_element?(view, "caption", "8 of 8 rule definitions for this asset")
    assert render(view) =~ "maximum of 8 rule definitions"
    refute has_element?(view, "button", "Prepare rule")
    render_click(view, "prepare", %{})
    assert has_element?(view, "[role=alert]", "already has eight rule definitions")
    refute has_element?(view, "#rule-definition")
  end

  test "an asset's protection page pages the alerts of its defined rules", c do
    thing = provisioned(c)
    path = Presenter.path(:asset, thing) <> "/protection"
    {:ok, view, _} = live(c.conn, path)
    assert has_element?(view, "p", "No alerts on this page.")

    generation =
      Enum.reduce(1..12, "3", fn index, generation ->
        thresholds = if rem(index, 2) == 1, do: {3.0, 3.2}, else: {2.5, 2.8}
        request = battery_rule(thing, generation, thresholds)

        {:ok, %{"generation" => next}} =
          Service.save_policy(c.service, c.admin, c.scope, Identifier.uuid(), request, c.now)

        next
      end)

    {:ok, %{"items" => all}} =
      Service.thing_alerts(c.service, c.reader, c.scope, thing, %{"limit" => 100}, c.now)

    assert length(all) > 10
    {:ok, detail, _} = live(c.conn, Presenter.alert_path(hd(all)["id"]))
    assert has_element?(detail, ~s(a[href="#{path}"]), "Asset protection and alerts")
    refute render(detail) =~ "No asset binding"
    view |> element("button", "Refresh") |> render_click()
    assert has_element?(view, "caption", "Alerts at scope version #{generation}")
    assert has_element?(view, ~s(a[href="#{Presenter.alert_path(hd(all)["id"])}"]))
    refute has_element?(view, "button", "Newer alerts")

    Agent.update(c.faults, &Map.put(&1, :thing_alerts, :unavailable))
    view |> element("button", "Older alerts") |> render_click()
    assert has_element?(view, "[role=alert]")
    assert has_element?(view, ~s(a[href="#{Presenter.alert_path(hd(all)["id"])}"]))

    view |> element("button", "Older alerts") |> render_click()
    older = Enum.drop(all, 10)
    assert has_element?(view, ~s(a[href="#{Presenter.alert_path(hd(older)["id"])}"]))
    refute has_element?(view, ~s(a[href="#{Presenter.alert_path(hd(all)["id"])}"]))
    view |> element("button", "Newer alerts") |> render_click()
    assert has_element?(view, ~s(a[href="#{Presenter.alert_path(hd(all)["id"])}"]))

    view |> element("button", "Older alerts") |> render_click()

    {:ok, _} =
      Service.save_policy(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        battery_rule(thing, generation, {3.0, 3.2}),
        c.now
      )

    view |> element("button", "Newer alerts") |> render_click()
    assert has_element?(view, "[role=alert]", "service changed")
    assert has_element?(view, ~s(a[href="#{Presenter.alert_path(hd(older)["id"])}"]))

    {:ok, %{"id" => reader}} = Sessions.login(c.sessions, c.reader, c.scope)
    reader_conn = build_conn() |> init_test_session(%{"browser_session" => reader})
    {:ok, reader_view, _} = live(reader_conn, path)
    assert has_element?(reader_view, "h2", "Alerts for this asset")
    assert has_element?(reader_view, "button", "Older alerts")

    Agent.update(c.faults, &Map.put(&1, :thing_alerts, :unavailable))
    view |> element("button", "Refresh") |> render_click()
    assert has_element?(view, "[role=status]", "Alerts are unavailable")
    refute has_element?(view, "button", "Older alerts")

    Agent.update(c.faults, &Map.put(&1, :thing_alerts, {:reply, {:ok, %{}}}))
    view |> element("button", "Refresh") |> render_click()
    assert has_element?(view, "[role=status]", "Alerts are unavailable")

    view |> element("button", "Refresh") |> render_click()
    assert has_element?(view, "button", "Older alerts")
    Agent.update(c.faults, &Map.put(&1, :thing_alerts, {:deny, "forbidden"}))
    view |> element("button", "Older alerts") |> render_click()
    assert has_element?(view, "[role=status]", "Alerts are unavailable")
  end

  test "an administrator removes an asset after confirmation and reconnects to the receipt", c do
    thing = provisioned(c)

    {:ok, _} =
      Service.save_policy(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        battery_rule(thing, "3", {2.5, 2.8}),
        c.now
      )

    path = Presenter.path(:asset, thing) <> "/remove"

    {:ok, asset, _} =
      live(c.conn, Presenter.path(:asset, thing) <> "?operation=" <> Identifier.uuid())

    assert has_element?(asset, ~s(a[href="#{path}"]), "Remove asset")

    {:ok, view, _} = live(c.conn, path)
    assert has_element?(view, "h2", "What removal does")
    assert render(view) =~ "1 rule definition is deleted"
    refute has_element?(view, "#remove-asset")
    view |> element("button", "Prepare removal") |> render_click()
    patched = assert_patch(view)
    assert has_element?(view, "#remove-asset")

    view |> form("#remove-asset") |> render_submit()
    assert has_element?(view, "[role=alert]", "Check the required fields")
    assert {:ok, _} = Service.get(c.service, c.admin, c.scope, "enrollments", thing, c.now)

    view |> form("#remove-asset", removal: %{confirmed: "yes"}) |> render_submit()
    assert has_element?(view, "[role=status]", "Asset removed")
    assert has_element?(view, ~s(a[href="/"]), "Return to assets")
    refute has_element?(view, "#remove-asset")

    assert {:error, %{"code" => "not_found"}} =
             Service.get(c.service, c.admin, c.scope, "enrollments", thing, c.now)

    assert {:ok, %{"items" => []}} =
             Service.thing_policies(c.service, c.reader, c.scope, thing, c.now)

    {:ok, resumed, _} = live(c.conn, patched)
    assert has_element?(resumed, "h1", "Asset removed")
    assert has_element?(resumed, "[role=status]", "Asset removed")
    render_submit(resumed, "remove", %{"removal" => %{"confirmed" => "yes"}})
    refute has_element?(resumed, "[role=alert]")

    {:ok, list, _} = live(c.conn, "/")
    refute has_element?(list, ".card")
  end

  test "asset removal refuses readers and stale snapshots and recovers uncertain replies", c do
    thing = provisioned(c)
    path = Presenter.path(:asset, thing) <> "/remove"

    {:ok, %{"id" => reader}} = Sessions.login(c.sessions, c.reader, c.scope)
    reader_conn = build_conn() |> init_test_session(%{"browser_session" => reader})
    {:ok, reader_view, _} = live(reader_conn, path)
    assert render(reader_view) =~ "cannot remove it"
    refute has_element?(reader_view, "button", "Prepare removal")
    render_click(reader_view, "prepare", %{})
    assert has_element?(reader_view, "[role=alert]")

    {:ok, forged, _} = live(reader_conn, path <> "?operation=" <> Identifier.uuid())
    refute has_element?(forged, "#remove-asset")
    render_submit(forged, "remove", %{"removal" => %{"confirmed" => "yes"}})
    assert has_element?(forged, "[role=alert]", "does not permit")

    {:ok, stale, _} = live(c.conn, path)
    stale |> element("button", "Prepare removal") |> render_click()
    assert_patch(stale)
    import_operation = Identifier.uuid()

    {:ok, _} =
      Service.submit(
        c.service,
        c.admin,
        c.scope,
        import_operation,
        import_request(%{id: "observation-removal"}, "3"),
        c.now
      )

    stale |> form("#remove-asset", removal: %{confirmed: "yes"}) |> render_submit()
    assert has_element?(stale, "[role=alert]", "service changed")
    refute has_element?(stale, "#remove-asset")
    assert {:ok, _} = Service.get(c.service, c.admin, c.scope, "enrollments", thing, c.now)

    {:ok, unrelated, _} = live(c.conn, path <> "?operation=" <> import_operation)
    assert has_element?(unrelated, "[role=alert]", "different workflow")

    {:ok, invalid, _} = live(c.conn, path <> "?operation=not-a-uuid")
    assert has_element?(invalid, "[role=alert]")
    refute has_element?(invalid, "#remove-asset")

    {:ok, failing, _} = live(c.conn, path)
    failing |> element("button", "Prepare removal") |> render_click()
    assert_patch(failing)
    Agent.update(c.faults, &Map.put(&1, :unenroll, :unavailable))
    failing |> form("#remove-asset", removal: %{confirmed: "yes"}) |> render_submit()
    assert has_element?(failing, "[role=status]", "Removal outcome unknown")
    failing |> element("button", "Check operation outcome") |> render_click()
    assert has_element?(failing, "[role=status]", "Removal outcome unknown")
    assert {:ok, _} = Service.get(c.service, c.admin, c.scope, "enrollments", thing, c.now)

    {:ok, lost, _} = live(c.conn, path)
    lost |> element("button", "Prepare removal") |> render_click()
    assert_patch(lost)
    Agent.update(c.faults, &Map.put(&1, :unenroll, :lost_reply))
    lost |> form("#remove-asset", removal: %{confirmed: "yes"}) |> render_submit()
    assert has_element?(lost, "[role=status]", "Removal outcome unknown")
    Agent.update(c.faults, &Map.put(&1, :get, :unavailable))
    lost |> element("button", "Check operation outcome") |> render_click()
    assert has_element?(lost, "[role=status]", "Removal outcome unknown")
    lost |> element("button", "Check operation outcome") |> render_click()
    assert has_element?(lost, "[role=status]", "Asset removed")

    Agent.update(c.faults, &Map.put(&1, :get, :unavailable))
    {:ok, gone, _} = live(c.conn, path)
    assert has_element?(gone, "h1", "Asset unavailable")
  end

  test "rule creation rejects readers, invalid input, stale snapshots and duplicate writes", c do
    {thing, _} = enrolled(c)
    path = Presenter.path(:asset, thing) <> "/protection"
    {:ok, unprovisioned, _} = live(c.conn, path)
    assert render(unprovisioned) =~ "Provision this asset before adding a rule"
    refute has_element?(unprovisioned, "button", "Prepare rule")

    materialize(c, thing, "2")
    {:ok, %{"id" => reader}} = Sessions.login(c.sessions, c.reader, c.scope)
    reader_conn = build_conn() |> init_test_session(%{"browser_session" => reader})
    {:ok, reader_view, _} = live(reader_conn, path)
    assert render(reader_view) =~ "cannot add rules"
    refute has_element?(reader_view, "button", "Prepare rule")
    render_click(reader_view, "prepare", %{})
    assert has_element?(reader_view, "[role=alert]")

    {:ok, view, _} = live(c.conn, path)
    view |> element("button", "Prepare rule") |> render_click()
    patched = assert_patch(view)

    for invalid <- [
          %{kind: "battery", low_threshold: "low", clear_threshold: "3.2"},
          %{kind: "battery", low_threshold: "3.2", clear_threshold: "3.0"},
          %{kind: "heartbeat", maximum_silence_seconds: "604801"},
          %{kind: "heartbeat", maximum_silence_seconds: "1.5"}
        ] do
      view |> form("#rule-definition", rule: invalid) |> render_submit()
      assert render(view) =~ "Check the required fields"
      assert has_element?(view, "#rule-definition")
    end

    render_submit(view, "save", %{"rule" => %{"kind" => "motion", "future_skew_seconds" => "0"}})
    assert has_element?(view, "#rule-definition")

    {:ok, _} =
      Service.submit(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        import_request(%{id: "observation-late"}, "3"),
        c.now
      )

    view |> form("#rule-definition", rule: %{kind: "heartbeat"}) |> render_submit()
    assert render(view) =~ "changed since this page loaded"

    assert {:ok, %{"items" => []}} =
             Service.list(c.service, c.admin, c.scope, "policies", %{}, c.now)

    {:ok, fresh, _} = live(c.conn, path)
    fresh |> element("button", "Prepare rule") |> render_click()
    fresh_path = assert_patch(fresh)
    Agent.update(c.faults, &Map.put(&1, :save_policy, :lost_reply))
    fresh |> form("#rule-definition", rule: %{kind: "heartbeat"}) |> render_submit()
    assert has_element?(fresh, "[role=status]", "Rule outcome unknown")
    refute has_element?(fresh, "#rule-definition")
    fresh |> element("button", "Check operation outcome") |> render_click()
    assert has_element?(fresh, "[role=status]", "Rule saved")

    render_submit(fresh, "save", %{"rule" => %{"kind" => "heartbeat"}})

    assert {:ok, %{"items" => [_]}} =
             Service.list(c.service, c.admin, c.scope, "policies", %{}, c.now)

    {:ok, unrelated, _} = live(c.conn, path <> "?operation=" <> operation_from(patched))
    refute has_element?(unrelated, "[role=status]")
    assert has_element?(unrelated, "#rule-definition")

    {:ok, reused, _} = live(c.conn, path <> "?operation=" <> operation_from(fresh_path))
    assert has_element?(reused, "[role=status]", "Rule saved")

    {:ok, invalid, _} = live(c.conn, path <> "?operation=not-a-uuid")
    assert has_element?(invalid, "[role=alert]")
    refute has_element?(invalid, "#rule-definition")
  end

  test "rule creation keeps uncertain and unrelated outcomes from submitting again", c do
    {thing, enroll_operation} = enrolled(c)
    materialize(c, thing, "2")
    path = Presenter.path(:asset, thing) <> "/protection"

    {:ok, missing, _} =
      live(c.conn, Presenter.path(:asset, "urn:uuid:" <> Identifier.uuid()) <> "/protection")

    assert has_element?(missing, "h1", "Asset unavailable")

    {:ok, view, _} = live(c.conn, path)
    Agent.update(c.faults, &Map.put(&1, :list, :unavailable))
    view |> element("button", "Prepare rule") |> render_click()
    assert has_element?(view, "[role=alert]")
    refute has_element?(view, "#rule-definition")
    render_click(view, "unknown-event", %{})

    {:ok, unrelated, _} = live(c.conn, path <> "?operation=" <> enroll_operation)
    assert render(unrelated) =~ "belongs to a different workflow"

    {:ok, failing, _} = live(c.conn, path)
    failing |> element("button", "Prepare rule") |> render_click()
    assert_patch(failing)

    render_submit(failing, "save", %{
      "rule" => %{"kind" => "heartbeat", "future_skew_seconds" => ["60"]}
    })

    render_submit(failing, "save", %{
      "rule" => %{"kind" => "battery", "future_skew_seconds" => "60"}
    })

    assert has_element?(failing, "#rule-definition")

    Agent.update(c.faults, &Map.put(&1, :save_policy, :unavailable))
    failing |> form("#rule-definition", rule: %{kind: "heartbeat"}) |> render_submit()
    assert has_element?(failing, "[role=status]", "Rule outcome unknown")

    assert {:ok, %{"items" => []}} =
             Service.list(c.service, c.admin, c.scope, "policies", %{}, c.now)

    {:ok, lost, _} = live(c.conn, path)
    lost |> element("button", "Prepare rule") |> render_click()
    assert_patch(lost)
    Agent.update(c.faults, &Map.put(&1, :save_policy, :lost_reply))
    lost |> form("#rule-definition", rule: %{kind: "heartbeat"}) |> render_submit()
    Agent.update(c.faults, &Map.put(&1, :get, :unavailable))
    lost |> element("button", "Check operation outcome") |> render_click()
    assert has_element?(lost, "[role=status]", "Rule outcome unknown")
    lost |> element("button", "Check operation outcome") |> render_click()
    assert has_element?(lost, "[role=status]", "Rule saved")

    {:ok, %{"id" => reader}} = Sessions.login(c.sessions, c.reader, c.scope)
    reader_conn = build_conn() |> init_test_session(%{"browser_session" => reader})
    {:ok, reader_view, _} = live(reader_conn, path <> "?operation=" <> Identifier.uuid())
    render_submit(reader_view, "save", %{"rule" => %{"kind" => "heartbeat"}})
    assert has_element?(reader_view, "[role=alert]")
  end

  test "an administrator edits and deletes a rule definition without repeating writes", c do
    thing = provisioned(c)

    battery = %{
      "id" => "low-battery",
      "kind" => "battery",
      "thing_id" => thing,
      "parameters" => %{
        "measurement_kind" => "batteryVoltage",
        "unit" => "V",
        "low_threshold" => 3.0,
        "clear_threshold" => 3.2,
        "maximum_age_ms" => 86_400_000,
        "future_skew_ms" => 60_000,
        "accept_suspect" => false
      },
      "expected_generation" => "3"
    }

    {:ok, _} = Service.save_policy(c.service, c.admin, c.scope, Identifier.uuid(), battery, c.now)
    path = Presenter.rule_path("battery:low-battery")

    {:ok, %{"id" => reader}} = Sessions.login(c.sessions, c.reader, c.scope)
    reader_conn = build_conn() |> init_test_session(%{"browser_session" => reader})
    {:ok, reader_view, _} = live(reader_conn, path)
    assert render(reader_view) =~ "revision 4"
    refute has_element?(reader_view, "button", "Prepare edit")
    render_click(reader_view, "prepare-manage", %{"intent" => "edit"})
    assert has_element?(reader_view, "[role=alert]")

    {:ok, view, _} = live(c.conn, path)
    assert has_element?(view, ".reading", "Low")
    view |> element("button", "Prepare edit") |> render_click()
    edit_path = assert_patch(view)
    assert has_element?(view, "#rule-low[value='3.0']")
    assert has_element?(view, "#rule-age[value='86400']")

    view |> form("#edit-rule", rule: %{low_threshold: "3.3"}) |> render_submit()
    assert render(view) =~ "Check the required fields"

    view
    |> form("#edit-rule", rule: %{low_threshold: "2.5", clear_threshold: "2.8"})
    |> render_submit()

    assert has_element?(view, "[role=status]", "Rule definition updated")
    assert has_element?(view, ".reading", "Normal")
    assert render(view) =~ "revision 5"
    refute has_element?(view, "#edit-rule")

    {:ok, resumed, _} = live(c.conn, edit_path)
    assert has_element?(resumed, "[role=status]", "Rule definition updated")
    refute has_element?(resumed, "#edit-rule")

    {:ok, stale, _} = live(c.conn, path)
    stale |> element("button", "Prepare delete") |> render_click()
    assert_patch(stale)

    {:ok, _} =
      Service.submit(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        import_request(%{id: "observation-late"}, "5"),
        c.now
      )

    stale |> element("button", "Delete rule definition") |> render_click()
    assert render(stale) =~ "changed since this page loaded"

    {:ok, delete, _} = live(c.conn, path)
    delete |> element("button", "Prepare delete") |> render_click()
    assert_patch(delete)
    Agent.update(c.faults, &Map.put(&1, :delete_policy, :lost_reply))
    delete |> element("button", "Delete rule definition") |> render_click()
    assert has_element?(delete, "[role=status]", "Operation outcome unknown")
    refute has_element?(delete, "button", "Delete rule definition")
    delete |> element("button", "Check operation outcome") |> render_click()
    assert has_element?(delete, "[role=status]", "Rule definition deleted")
    assert render(delete) =~ "No active service definition"
    assert has_element?(delete, ".reading", "Normal")
    assert {:ok, []} = Store.scheduled_rules(c.store, 10)

    assert {:error, %{"code" => "not_found"}} =
             Service.get(c.service, c.admin, c.scope, "policies", "low-battery", c.now)

    precise = %{
      "id" => "precise-silence",
      "kind" => "heartbeat",
      "thing_id" => thing,
      "parameters" => %{"maximum_silence_ms" => 1_500, "future_skew_ms" => 0},
      "expected_generation" => "7"
    }

    {:ok, _} = Service.save_policy(c.service, c.admin, c.scope, Identifier.uuid(), precise, c.now)
    {:ok, precise_view, _} = live(c.conn, Presenter.rule_path("heartbeat:precise-silence"))
    assert render(precise_view) =~ "represented exactly by this form"
    refute has_element?(precise_view, "button", "Prepare edit")
    assert has_element?(precise_view, "button", "Prepare delete")
    render_click(precise_view, "prepare-manage", %{"intent" => "edit"})
    assert has_element?(precise_view, "[role=alert]")
  end

  test "an administrator edits a complete motion definition without changing retained state", c do
    thing = provisioned(c)
    RuleFixtures.commit_motion(c.store, c.scope)

    definition = %{
      "id" => "trips",
      "kind" => "motion",
      "thing_id" => thing,
      "parameters" => %{
        "event_time" => "trusted_fix",
        "future_skew_ms" => 0,
        "late_window_ms" => 10_000,
        "sequence" => "none",
        "moving_speed_m_s" => 1.0,
        "stationary_speed_m_s" => 0.1,
        "moving_distance_m" => 1.0,
        "stationary_distance_m" => 0.5,
        "max_plausible_speed_m_s" => 10_000.0,
        "max_gap_ms" => 10_000,
        "uncertainty" => "coordinate_only",
        "minimum_movement_ms" => 1_000,
        "minimum_stop_ms" => 1_000
      },
      "expected_generation" => "6"
    }

    assert {:ok, %{"generation" => "7"}} =
             Service.save_policy(
               c.service,
               c.admin,
               c.scope,
               Identifier.uuid(),
               definition,
               c.now
             )

    path = Presenter.rule_path("motion:trips")
    {:ok, view, _} = live(c.conn, path)
    assert has_element?(view, ".reading", "Moving")
    assert has_element?(view, "button", "Prepare edit")
    view |> element("button", "Prepare edit") |> render_click()
    assert_patch(view)
    assert has_element?(view, "#rule-moving-speed[value='1.0']")
    assert has_element?(view, "#rule-movement-dwell[value='1']")

    view
    |> form("#edit-rule", rule: %{moving_speed_m_s: "2.0"})
    |> render_submit()

    assert has_element?(view, "[role=status]", "Rule definition updated")
    assert has_element?(view, ".reading", "Moving")
    assert render(view) =~ "different revision"

    assert {:ok, %{"value" => revised}} =
             Service.get(c.service, c.reader, c.scope, "policies", "trips", c.now)

    assert revised["parameters"]["moving_speed_m_s"] == 2.0
    assert revised["parameters"]["max_plausible_speed_m_s"] == 10_000.0
  end

  test "rule management keeps unrelated, failed and foreign definitions out of changes", c do
    {thing, enroll_operation} = enrolled(c)
    materialize(c, thing, "2")
    RuleFixtures.commit_heartbeat(c.store, c.scope)

    foreign = %{
      "id" => "silence",
      "kind" => "battery",
      "thing_id" => thing,
      "parameters" => %{
        "measurement_kind" => "batteryVoltage",
        "unit" => "V",
        "low_threshold" => 2.5,
        "clear_threshold" => 2.8,
        "maximum_age_ms" => 86_400_000,
        "future_skew_ms" => 60_000,
        "accept_suspect" => false
      },
      "expected_generation" => "5"
    }

    {:ok, _} = Service.save_policy(c.service, c.admin, c.scope, Identifier.uuid(), foreign, c.now)
    {:ok, host_rule, _} = live(c.conn, Presenter.rule_path("heartbeat:silence"))
    assert render(host_rule) =~ "No active service definition"
    refute has_element?(host_rule, "button", "Prepare delete")

    {:ok, orphan, _} =
      live(
        c.conn,
        Presenter.rule_path("heartbeat:silence") <>
          "?manage_operation=#{Identifier.uuid()}&manage_intent=delete"
      )

    refute has_element?(orphan, "button", "Delete rule definition")

    path = Presenter.rule_path("battery:silence")
    {:ok, view, _} = live(c.conn, path)
    render_click(view, "unknown-event", %{})
    render_click(view, "prepare-manage", %{"intent" => "archive"})
    assert has_element?(view, "[role=alert]")
    render_submit(view, "edit", %{"rule" => %{"low_threshold" => "2.4"}})
    assert has_element?(view, "[role=alert]")

    Agent.update(c.faults, &Map.put(&1, :list, :unavailable))
    view |> element("button", "Prepare edit") |> render_click()
    assert has_element?(view, "[role=alert]")
    refute has_element?(view, "#edit-rule")

    view |> element("button", "Prepare edit") |> render_click()
    prepared = assert_patch(view)
    {:ok, reconnected, _} = live(c.conn, prepared)
    assert has_element?(reconnected, "#edit-rule")

    Agent.update(c.faults, &Map.put(&1, :save_policy, :unavailable))
    reconnected |> form("#edit-rule", rule: %{low_threshold: "2.4"}) |> render_submit()
    assert has_element?(reconnected, "[role=status]", "Operation outcome unknown")

    {:ok, lost, _} = live(c.conn, path)
    lost |> element("button", "Prepare edit") |> render_click()
    assert_patch(lost)
    Agent.update(c.faults, &Map.put(&1, :save_policy, :lost_reply))
    lost |> form("#edit-rule", rule: %{low_threshold: "2.4"}) |> render_submit()
    Agent.update(c.faults, &Map.put(&1, :get, :unavailable))
    lost |> element("button", "Check operation outcome") |> render_click()
    assert has_element?(lost, "[role=status]", "Operation outcome unknown")
    lost |> element("button", "Check operation outcome") |> render_click()
    assert has_element?(lost, "[role=status]", "Rule definition updated")

    {:ok, unrelated, _} =
      live(c.conn, path <> "?manage_operation=#{enroll_operation}&manage_intent=edit")

    assert render(unrelated) =~ "belongs to a different workflow"

    for query <- [
          "?manage_operation=not-a-uuid&manage_intent=edit",
          "?manage_operation=#{Identifier.uuid()}&manage_intent=archive"
        ] do
      {:ok, invalid, _} = live(c.conn, path <> query)
      assert has_element?(invalid, "[role=alert]")
      refute has_element?(invalid, "#edit-rule")
    end
  end

  test "a suspicious alert explains reviewed trigger conditions without private identities", c do
    alert = suspicious_alert("explicit_owner_absence", c.now)
    Agent.update(c.faults, &Map.put(&1, :get, {:get_page, {:ok, %{"value" => alert}}}))
    {:ok, view, _} = live(c.conn, Presenter.alert_path("suspicious-alert"))

    assert has_element?(view, "h1", "Suspicious movement")
    assert has_element?(view, "dt", "Movement at evaluation")
    assert render(view) =~ "Confirmed moving"
    assert has_element?(view, "dt", "Arming at evaluation")
    assert has_element?(view, "dd", ~r/^\s*Armed\s*$/)
    assert has_element?(view, "dt", "Owner presence at evaluation")
    assert has_element?(view, "dd", "Explicitly absent")
    assert render(view) =~ "owner-presence state may differ"

    for private <- ~w(
      motion_state_identity armed_fact_identity owner_presence_fact_identity
      movement_position_evidence_id armed_evidence_id owner_presence_evidence_id
    ) do
      refute render(view) =~ private
    end

    unknown = suspicious_alert("unknown_treated_as_absent", c.now)
    Agent.update(c.faults, &Map.put(&1, :get, {:get_page, {:ok, %{"value" => unknown}}}))
    view |> element("button", "Refresh") |> render_click()
    assert render(view) =~ "Unknown, treated as absent by this rule revision"

    malformed = suspicious_alert("changed", c.now)
    Agent.update(c.faults, &Map.put(&1, :get, {:get_page, {:ok, %{"value" => malformed}}}))
    view |> element("button", "Refresh") |> render_click()
    assert has_element?(view, "dt", "Owner presence at evaluation")
    assert has_element?(view, "dd", "Unavailable")
  end

  test "an administrator acknowledges the newest alert once without private references", c do
    RuleFixtures.commit_all(c.store, c.scope)
    {:ok, protection, _} = live(c.conn, "/protection")
    assert has_element?(protection, ~s(a[href="/protection/alerts"]), "Review alerts")

    {:ok, list, _} = live(c.conn, "/protection/alerts")

    for {title, index} <-
          Enum.with_index(
            [
              "Geofence entered",
              "Trip started",
              "Transport degraded",
              "Battery low",
              "Reporting overdue"
            ],
            1
          ) do
      assert has_element?(list, ".card:nth-child(#{index}) h2", title)
    end

    assert has_element?(list, ".card", "Needs review")

    for private <- ~w(capture private-hardware _evidence_id latitude) do
      refute render(list) =~ private
    end

    {:ok, %{"items" => [%{"id" => newest} | _] = alerts}} =
      Service.list(c.service, c.reader, c.scope, "alerts", %{}, c.now)

    path = Presenter.alert_path(newest)

    {:ok, %{"id" => reader}} = Sessions.login(c.sessions, c.reader, c.scope)
    reader_conn = build_conn() |> init_test_session(%{"browser_session" => reader})
    {:ok, reader_view, _} = live(reader_conn, path)
    assert has_element?(reader_view, ".reading", "Needs review")
    refute has_element?(reader_view, "button", "Prepare acknowledgement")
    render_click(reader_view, "prepare", %{})
    render_click(reader_view, "acknowledge", %{})

    {:ok, view, _} = live(c.conn, path)
    assert has_element?(view, "h1", "Geofence entered")
    assert render(view) =~ "Outside to Inside"
    assert has_element?(view, ~s(a[href="/protection/geofence%3Ayard-membership"]))
    assert render(view) =~ "any Action would need separate authorization"
    render_click(view, "acknowledge", %{})
    assert has_element?(view, "[role=alert]")

    view |> element("button", "Prepare acknowledgement") |> render_click()
    patched = assert_patch(view)
    Agent.update(c.faults, &Map.put(&1, :acknowledge_alert, :lost_reply))
    view |> element("button", "Acknowledge alert") |> render_click()
    assert has_element?(view, "[role=status]", "Acknowledgement outcome unknown")
    refute has_element?(view, "button", "Acknowledge alert")
    view |> element("button", "Check operation outcome") |> render_click()
    assert has_element?(view, "[role=status]", "Alert acknowledged")
    assert has_element?(view, ".reading", "Acknowledged")
    refute has_element?(view, "button", "Prepare acknowledgement")

    {:ok, resumed, _} = live(c.conn, patched)
    assert has_element?(resumed, "[role=status]", "Alert acknowledged")

    [_, _, _, %{"id" => battery}, %{"id" => heartbeat}] = alerts
    {:ok, stale, _} = live(c.conn, Presenter.alert_path(battery))
    assert render(stale) =~ "No asset binding"
    stale |> element("button", "Prepare acknowledgement") |> render_click()
    assert_patch(stale)

    {:ok, _} =
      Service.acknowledge_alert(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        %{"alert_id" => heartbeat, "expected_generation" => "12"},
        c.now
      )

    stale |> element("button", "Acknowledge alert") |> render_click()
    assert render(stale) =~ "changed since this page loaded"

    Agent.update(c.faults, &Map.put(&1, :list, :unavailable))
    {:ok, failing, _} = live(c.conn, Presenter.alert_path(battery))
    Agent.update(c.faults, &Map.put(&1, :list, :unavailable))
    failing |> element("button", "Prepare acknowledgement") |> render_click()
    assert has_element?(failing, "[role=alert]")

    {:ok, missing, _} = live(c.conn, Presenter.alert_path("alert-missing"))
    assert has_element?(missing, "h1", "Alert unavailable")

    {:ok, invalid, _} = live(c.conn, Presenter.alert_path(battery) <> "?operation=not-a-uuid")
    assert has_element?(invalid, "[role=alert]")
  end

  test "alert pages revisit earlier pages and replay alerts need no review", c do
    RuleFixtures.commit_heartbeat_versions(c.store, c.scope, "silence", 27)
    {:ok, list, _} = live(c.conn, "/protection/alerts")
    assert has_element?(list, ".card h2", "Reporting recovered")
    list |> element("button", "Next page") |> render_click()
    assert has_element?(list, "button", "Previous page")
    refute has_element?(list, "button", "Next page")

    Agent.update(c.faults, &Map.put(&1, :list, :unavailable))
    list |> element("button", "Previous page") |> render_click()
    assert has_element?(list, "[role=alert]")
    list |> element("button", "Previous page") |> render_click()
    refute has_element?(list, "button", "Previous page")

    list |> element("button", "Next page") |> render_click()
    RuleFixtures.commit_heartbeat_versions(c.store, c.scope, "other", 2)
    list |> element("button", "Previous page") |> render_click()
    assert render(list) =~ "changed since this page loaded"
    list |> element("button", "Refresh") |> render_click()
    render_click(list, "unknown-event", %{})

    Agent.update(c.faults, &Map.put(&1, :list, {:deny, "forbidden"}))
    list |> element("button", "Refresh") |> render_click()
    refute has_element?(list, ".card")

    policy = RuleFixtures.heartbeat_policy("replayed")
    capture = observation(%{id: "replay-capture", observed_at: c.now})
    {:ok, baseline} = HeartbeatTransition.evaluate(nil, capture, policy, :replay, c.now)
    {:ok, first} = RuleTransition.new(c.scope, nil, baseline)
    {:ok, _} = Store.commit_rule(c.store, first)
    state = baseline["state"]
    {:ok, overdue} = HeartbeatTransition.evaluate(state, nil, policy, :replay, state.due_at)
    {:ok, second} = RuleTransition.new(c.scope, state, overdue)
    {:ok, receipt} = Store.commit_rule(c.store, second)

    {:ok, %{"items" => [%{"id" => replayed} | _]}} =
      Service.list(c.service, c.reader, c.scope, "alerts", %{}, c.now)

    assert String.ends_with?(replayed, receipt["event_id"])
    {:ok, replay_view, _} = live(c.conn, Presenter.alert_path(replayed))
    assert has_element?(replay_view, ".reading", "Replay record")
    assert render(replay_view) =~ "None can be dispatched from this record"
    refute has_element?(replay_view, "button", "Prepare acknowledgement")
    replay_view |> element("button", "Refresh") |> render_click()
    render_click(replay_view, "unknown-event", %{})
  end

  test "alert acknowledgement keeps unrelated, failed and unverified outcomes uncertain", c do
    RuleFixtures.commit_all(c.store, c.scope)

    {:ok, %{"items" => [%{"id" => newest}, %{"id" => trip} | _]}} =
      Service.list(c.service, c.reader, c.scope, "alerts", %{}, c.now)

    other_operation = Identifier.uuid()

    {:ok, _} =
      Service.acknowledge_alert(
        c.service,
        c.admin,
        c.scope,
        other_operation,
        %{"alert_id" => trip, "expected_generation" => "11"},
        c.now
      )

    path = Presenter.alert_path(newest)
    {:ok, unrelated, _} = live(c.conn, path <> "?operation=" <> other_operation)
    assert render(unrelated) =~ "belongs to a different workflow"
    refute has_element?(unrelated, "button", "Acknowledge alert")

    {:ok, reconnected, _} = live(c.conn, path <> "?operation=" <> Identifier.uuid())
    assert has_element?(reconnected, "button", "Acknowledge alert")

    Agent.update(c.faults, &Map.put(&1, :get, :unavailable))
    reconnected |> element("button", "Refresh") |> render_click()
    assert has_element?(reconnected, "[role=alert]")
    assert has_element?(reconnected, ".reading", "Needs review")

    Agent.update(c.faults, &Map.put(&1, :acknowledge_alert, :unavailable))
    reconnected |> element("button", "Acknowledge alert") |> render_click()
    assert has_element?(reconnected, "[role=status]", "Acknowledgement outcome unknown")

    {:ok, lost, _} = live(c.conn, path)
    lost |> element("button", "Prepare acknowledgement") |> render_click()
    assert_patch(lost)
    Agent.update(c.faults, &Map.put(&1, :acknowledge_alert, :lost_reply))
    lost |> element("button", "Acknowledge alert") |> render_click()
    Agent.update(c.faults, &Map.put(&1, :get, :unavailable))
    lost |> element("button", "Check operation outcome") |> render_click()
    assert has_element?(lost, "[role=status]", "Acknowledgement outcome unknown")
    lost |> element("button", "Check operation outcome") |> render_click()
    assert has_element?(lost, "[role=status]", "Alert acknowledged")
  end

  test "saved table dashboard keeps multiple series and exposes a failed rerun", c do
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

    dashboard = "two-series-dashboard"

    {:ok, _} =
      Service.save_query(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        %{
          "id" => dashboard,
          "title" => "Two series",
          "query" => dashboard_query([thing, "unobserved-series"], c.now),
          "visualization" => %{"type" => "table", "show_legend" => true, "show_points" => false},
          "expected_generation" => "3"
        },
        c.now
      )

    {:ok, view, html} = live(c.conn, Presenter.dashboard_path(dashboard))
    assert html =~ "Fixed absolute UTC bounds"
    view |> element("button", "Run saved query") |> render_click()
    assert render(view) =~ "24.3"
    assert render(view) =~ "No qualified readings in this series"
    assert has_element?(view, "caption", "Qualified buckets for #{thing}")
    assert has_element?(view, "caption", "Qualified buckets for unobserved-series")
    refute has_element?(view, "svg[role=img]")

    Agent.update(c.faults, &Map.put(&1, :execute_saved_query, :unavailable))
    view |> element("button", "Run saved query") |> render_click()
    assert has_element?(view, "[role=alert]")
    refute has_element?(view, "h2", "Query result")

    view |> element("button", "Run saved query") |> render_click()
    assert render(view) =~ "No qualified readings in this series"
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
    assert has_element?(picker, "button", "Previous page")
    picker |> element("button", "Previous page") |> render_click()
    assert has_element?(picker, "button", "Next page")
    picker |> element("button", "Next page") |> render_click()

    assert {:ok, _} =
             Service.submit(
               c.service,
               c.admin,
               c.scope,
               Identifier.uuid(),
               import_request(%{id: "later-27", observed_at: c.now + 27}, "27"),
               c.now
             )

    picker |> element("button", "Previous page") |> render_click()
    assert has_element?(picker, "button", "Previous page")
    assert render(picker) =~ "changed since this page loaded"
    picker |> element("button", "Refresh") |> render_click()
    refute has_element?(picker, "button", "Previous page")

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
    assert has_element?(view, "button", "Previous page")
    assert has_element?(view, "a", "Inspect observation")

    Agent.update(c.faults, &Map.put(&1, :list, :unavailable))
    view |> element("button", "Previous page") |> render_click()
    assert has_element?(view, "button", "Previous page")
    assert has_element?(view, "a", "Inspect observation")

    view |> element("button", "Previous page") |> render_click()
    assert has_element?(view, "button", "Next page")
    refute has_element?(view, "button", "Previous page")

    view |> element("button", "Next page") |> render_click()
    assert has_element?(view, "button", "Previous page")

    assert {:ok, _} =
             Service.submit(
               c.service,
               c.admin,
               c.scope,
               Identifier.uuid(),
               import_request(%{id: "observation-26", observed_at: c.now + 26}, "26"),
               c.now
             )

    view |> element("button", "Previous page") |> render_click()
    assert has_element?(view, "button", "Previous page")
    assert render(view) =~ "changed since this page loaded"

    Agent.update(c.faults, &Map.put(&1, :list, :unavailable))
    view |> element("button", "Refresh") |> render_click()
    assert render(view) =~ "service could not complete"
    assert has_element?(view, "a", "Inspect observation")
    assert has_element?(view, "button", "Previous page")
    view |> element("button", "Refresh") |> render_click()
    assert has_element?(view, "button", "Next page")
    refute has_element?(view, "button", "Previous page")

    view |> element("button", "Next page") |> render_click()
    Agent.update(c.faults, &Map.put(&1, :list, {:deny, "forbidden"}))
    view |> element("button", "Previous page") |> render_click()
    refute has_element?(view, "button", "Previous page")
    refute has_element?(view, "a", "Inspect observation")
    assert has_element?(view, "[role=alert]")

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

  test "route history uses the authorized service and explains positionless retained data", c do
    thing = provisioned(c)

    {:ok, asset, _} =
      live(c.conn, Presenter.path(:asset, thing) <> "?operation=" <> Identifier.uuid())

    assert has_element?(
             asset,
             ~s(a[href="#{Presenter.path(:asset, thing)}/route"]),
             "Explore route history"
           )

    path = Presenter.path(:asset, thing) <> "/route"
    {:ok, route, html} = live(c.conn, path)
    assert html =~ "Workshop sensor route"
    assert has_element?(route, "#route-query")
    assert has_element?(route, "h2", "Route page")
    assert render(route) =~ "No position in this materialisation"
    assert render(route) =~ "No qualified position can be plotted"
    assert render(route) =~ "Continuity is local to this page"

    route |> element("button", "Export this route page (JSON)") |> render_click()
    assert_push_event(route, "download-route-page", %{"content" => route_json})
    route_export = Jason.decode!(route_json)
    assert route_export["schema"] == "wtr.route-page-export.v1"
    assert route_export["thing_id"] == thing
    assert route_export["continuity"] == "page_local_only"
    assert route_export["has_more"] == false
    refute Map.has_key?(route_export, "cursor")
    refute route_json =~ "wtrc1."

    Agent.update(c.faults, &Map.put(&1, :route_history, :unavailable))
    route |> element("button", "Export this route page (JSON)") |> render_click()
    refute_push_event(route, "download-route-page", %{"content" => _})
    assert has_element?(route, "h2", "Route page")
    assert has_element?(route, "[role=alert]")

    route |> element("button", "Export this route page (JSON)") |> render_click()
    assert_push_event(route, "download-route-page", %{"content" => _})

    render_patch(route, path)
    route |> element("button", "Refresh asset") |> render_click()
    route |> form("#route-query") |> render_submit()
    assert has_element?(route, "h2", "Route page")
    render_submit(route, "run", %{})
    assert has_element?(route, "[role=alert]", "Check the required fields")
    render_click(route, "unknown-event", %{})

    route |> element("button", "Refresh asset") |> render_click()

    route
    |> form("#route-query", route: %{from: "2023-11-14T00:00:00+02:00"})
    |> render_submit()

    assert has_element?(route, "[role=alert]", "Check the required fields")
    refute has_element?(route, "h2", "Route page")

    Agent.update(c.faults, &Map.put(&1, :get, :unavailable))
    route |> element("button", "Refresh asset") |> render_click()
    refute has_element?(route, "#route-query")

    Agent.update(c.faults, &Map.put(&1, :get, {:reply, {:ok, %{}}}))
    route |> element("button", "Refresh asset") |> render_click()
    assert has_element?(route, "[role=alert]")
  end

  test "route pages plot separate segments and retain the current page on retry", c do
    thing = provisioned(c)
    first = route_page(thing, c.now, "cursor-one", "route-page-one")
    second = route_page(thing, c.now + 5_000, nil, "route-page-two")
    Agent.update(c.faults, &Map.put(&1, :route_history, {:route_page, first}))

    {:ok, view, html} = live(c.conn, Presenter.path(:asset, thing) <> "/route")
    assert html =~ "route-page-one"
    assert length(Regex.scan(~r/class="chart-line"/, html)) == 2
    assert length(Regex.scan(~r/class="chart-point"/, html)) == 3
    assert html =~ "Missing or ambiguous materialisation"
    assert html =~ "Multiple positions; no source selected"
    assert html =~ "Quality excluded: suspect"
    refute html =~ "private-position-evidence"
    assert has_element?(view, "button", "Next route page")
    refute has_element?(view, "button", "Previous route page")

    Agent.update(c.faults, &Map.put(&1, :route_history, :unavailable))
    view |> element("button", "Next route page") |> render_click()
    assert render(view) =~ "route-page-one"
    assert has_element?(view, "[role=alert]")
    refute has_element?(view, "button", "Previous route page")

    Agent.update(c.faults, &Map.put(&1, :route_history, {:reply, {:ok, second}}))
    view |> element("button", "Next route page") |> render_click()
    assert render(view) =~ "route-page-two"
    assert has_element?(view, "button", "Previous route page")
    refute has_element?(view, "button", "Next route page")

    Agent.update(c.faults, &Map.put(&1, :route_history, :unavailable))
    view |> element("button", "Previous route page") |> render_click()
    assert render(view) =~ "route-page-two"
    assert has_element?(view, "button", "Previous route page")

    Agent.update(c.faults, &Map.put(&1, :route_history, {:reply, {:ok, first}}))
    view |> element("button", "Previous route page") |> render_click()
    assert render(view) =~ "route-page-one"
    refute has_element?(view, "button", "Previous route page")

    for response <- [
          {:ok, %{}},
          {:ok, put_in(first, ["route"], %{})},
          {:ok, "unexpected"}
        ] do
      Agent.update(c.faults, &Map.put(&1, :route_history, {:reply, response}))
      view |> element("button", "Next route page") |> render_click()
      assert render(view) =~ "route-page-one"
      assert has_element?(view, "[role=alert]")
      refute has_element?(view, "button", "Previous route page")
    end

    Agent.update(c.faults, &Map.put(&1, :route_history, {:reply, {:ok, second}}))
    view |> element("button", "Export this route page (JSON)") |> render_click()
    refute_push_event(view, "download-route-page", %{"content" => _})
    refute has_element?(view, "h2", "Route page")
    assert has_element?(view, "[role=alert]", "service changed")

    view |> element("button", "Refresh asset") |> render_click()
    assert has_element?(view, "h2", "Route page")

    Agent.update(c.faults, &Map.put(&1, :route_history, {:deny, "forbidden"}))
    view |> element("button", "Export this route page (JSON)") |> render_click()
    refute has_element?(view, "#route-query")
    refute has_element?(view, "h2", "Route page")
    assert has_element?(view, "[role=alert]", "does not permit")
  end

  test "route history distinguishes an unprovisioned asset from a missing one", c do
    {thing, _} = enrolled(c)
    {:ok, unprovisioned, _} = live(c.conn, Presenter.path(:asset, thing) <> "/route")
    assert has_element?(unprovisioned, ".notice", "Provision this asset's Thing")
    refute has_element?(unprovisioned, "#route-query")

    {:ok, missing, _} =
      live(c.conn, Presenter.path(:asset, "urn:uuid:" <> Identifier.uuid()) <> "/route")

    assert has_element?(missing, "[role=alert]", "requested record is not available")
    refute has_element?(missing, "#route-query")
  end

  test "trip history uses the authorized service and exports the exact empty page", c do
    thing = provisioned(c)

    {:ok, asset, _} =
      live(c.conn, Presenter.path(:asset, thing) <> "?operation=" <> Identifier.uuid())

    assert has_element?(
             asset,
             ~s(a[href="#{Presenter.path(:asset, thing)}/trips"]),
             "Explore trips and stops"
           )

    path = Presenter.path(:asset, thing) <> "/trips"
    {:ok, trips, html} = live(c.conn, path)
    assert html =~ "Workshop sensor trips"
    assert has_element?(trips, "#trip-page-size")
    assert has_element?(trips, "h2", "Trip event timeline")
    assert has_element?(trips, ".empty", "No trip events on this page")
    assert render(trips) =~ "never invents a missing stop"

    trips |> element("button", "Export this event page (JSON)") |> render_click()
    assert_push_event(trips, "download-trip-page", %{"content" => json})
    export = Jason.decode!(json)
    assert export["schema"] == "wtr.trip-event-page-export.v1"
    assert export["thing_id"] == thing
    assert export["items"] == []
    assert export["has_more"] == false

    assert export["window"] == %{
             "from_at" => c.now + 1 - 2_592_000_000,
             "to_at" => c.now + 1
           }

    assert export["presentation"] == %{
             "duration_unit" => "milliseconds",
             "fixed_offset_minutes" => 0,
             "timezone" => "UTC",
             "timezone_key" => "utc"
           }

    refute Map.has_key?(export, "cursor")
    refute json =~ "wtrc1."

    Agent.update(c.faults, &Map.put(&1, :thing_trips, :unavailable))
    trips |> element("button", "Export this event page (JSON)") |> render_click()
    refute_push_event(trips, "download-trip-page", %{"content" => _})
    assert has_element?(trips, "h2", "Trip event timeline")
    assert has_element?(trips, "[role=alert]")

    trips |> element("button", "Export this event page (JSON)") |> render_click()
    assert_push_event(trips, "download-trip-page", %{"content" => _})

    trips
    |> form("#trip-page-size",
      trip: %{
        from: trip_iso(c.now + 1 - 2_592_000_000),
        to: trip_iso(c.now + 1),
        timezone: "utc",
        duration_unit: "milliseconds",
        limit: "50"
      }
    )
    |> render_submit()

    assert has_element?(trips, ~s(#trip-limit option[selected][value="50"]))
    render_submit(trips, "set-limit", %{})
    assert has_element?(trips, "[role=alert]", "Check the required fields")

    render_submit(trips, "set-limit", %{
      "trip" => %{
        "from" => "2023-01-01T00:00:00+01:00",
        "to" => "2023-01-02T00:00:00Z",
        "timezone" => "utc",
        "duration_unit" => "milliseconds",
        "limit" => "25"
      }
    })

    assert has_element?(trips, "[role=alert]", "Check the required fields")

    render_submit(trips, "set-limit", %{
      "trip" => %{
        "from" => "2023-01-01T00:00:00Z",
        "to" => "2023-01-02T00:00:00Z",
        "timezone" => "Europe/Stockholm",
        "duration_unit" => "minutes",
        "limit" => "25"
      }
    })

    assert has_element?(trips, "[role=alert]", "Check the required fields")
    render_click(trips, "unknown-event", %{})

    Agent.update(c.faults, &Map.put(&1, :get, :unavailable))
    trips |> element("button", "Refresh trips") |> render_click()
    refute has_element?(trips, "#trip-page-size")

    Agent.update(c.faults, &Map.put(&1, :get, {:reply, {:ok, %{}}}))
    trips |> element("button", "Refresh trips") |> render_click()
    assert has_element?(trips, "[role=alert]")
  end

  test "trip pages pair only visible endpoints and retain the current page on retry", c do
    thing = provisioned(c)
    first = trip_page(thing, c.now - 10_000, "cursor-one", "10")
    second = trip_page(thing, c.now - 20_000, nil, "10", :single)
    Agent.update(c.faults, &Map.put(&1, :thing_trips, {:trip_page, first}))

    {:ok, view, html} = live(c.conn, Presenter.path(:asset, thing) <> "/trips")
    assert html =~ "Trip stopped"
    assert html =~ "Trip started"
    assert html =~ "Trip interrupted"
    assert html =~ "exact onset-to-ending interval 4500 ms"
    assert html =~ "Its stop event is also visible on this page"
    assert html =~ "Its start event is not visible on this page"
    assert html =~ "Historical replay; no present-time action"
    refute html =~ "private-position-evidence"
    assert has_element?(view, "button", "Next event page")
    refute has_element?(view, "button", "Previous event page")

    view
    |> form("#trip-page-size",
      trip: %{
        from: trip_iso(c.now + 1 - 2_592_000_000),
        to: trip_iso(c.now + 1),
        timezone: "utc_plus_02",
        duration_unit: "seconds",
        limit: "25"
      }
    )
    |> render_submit()

    assert render(view) =~ "UTC+02:00"
    assert render(view) =~ "exact onset-to-ending interval 4.5 s (4500 ms exact)"
    assert render(view) =~ "fixed offsets do not follow daylight-saving"

    view |> element("button", "Export this event page (JSON)") |> render_click()
    assert_push_event(view, "download-trip-page", %{"content" => selected_json})
    selected_export = Jason.decode!(selected_json)
    assert selected_export["window"]["to_at"] == c.now + 1

    assert selected_export["presentation"] == %{
             "duration_unit" => "seconds",
             "fixed_offset_minutes" => 120,
             "timezone" => "UTC+02:00 fixed",
             "timezone_key" => "utc_plus_02"
           }

    Agent.update(c.faults, &Map.put(&1, :thing_trips, :unavailable))
    view |> element("button", "Next event page") |> render_click()
    assert render(view) =~ "Trip stopped"
    assert has_element?(view, "[role=alert]")
    refute has_element?(view, "button", "Previous event page")

    Agent.update(c.faults, &Map.put(&1, :thing_trips, {:reply, {:ok, second}}))
    view |> element("button", "Next event page") |> render_click()
    assert render(view) =~ "trip-page-two"
    assert has_element?(view, "button", "Previous event page")
    refute has_element?(view, "button", "Next event page")

    Agent.update(c.faults, &Map.put(&1, :thing_trips, :unavailable))
    view |> element("button", "Previous event page") |> render_click()
    assert render(view) =~ "trip-page-two"
    assert has_element?(view, "button", "Previous event page")

    changed_generation = %{first | "generation" => "11"}
    Agent.update(c.faults, &Map.put(&1, :thing_trips, {:reply, {:ok, changed_generation}}))
    view |> element("button", "Previous event page") |> render_click()
    assert render(view) =~ "trip-page-two"
    assert has_element?(view, "[role=alert]", "service changed")

    Agent.update(c.faults, &Map.put(&1, :thing_trips, {:reply, {:ok, first}}))
    view |> element("button", "Previous event page") |> render_click()
    assert render(view) =~ "trip-page-one"
    refute has_element?(view, "button", "Previous event page")

    for response <- [
          {:ok, %{}},
          {:ok, put_in(first, ["items", Access.at(0), "value", "event", "kind"], "battery.low")},
          {:ok,
           put_in(
             first,
             ["items", Access.at(0), "value", "event", "from_position_evidence_id"],
             "private-position-evidence"
           )},
          {:ok,
           put_in(
             first,
             ["items", Access.at(0), "value", "event", "effective_at"],
             c.now + 1
           )},
          {:ok, "unexpected"}
        ] do
      Agent.update(c.faults, &Map.put(&1, :thing_trips, {:reply, response}))
      view |> element("button", "Next event page") |> render_click()
      assert render(view) =~ "trip-page-one"
      assert has_element?(view, "[role=alert]")
      refute has_element?(view, "button", "Previous event page")
    end

    Agent.update(c.faults, &Map.put(&1, :thing_trips, {:reply, {:ok, %{}}}))
    view |> element("button", "Export this event page (JSON)") |> render_click()
    refute_push_event(view, "download-trip-page", %{"content" => _})
    refute has_element?(view, ".trip-timeline")
    assert has_element?(view, "[role=alert]", "service changed")

    Agent.update(c.faults, &Map.put(&1, :thing_trips, {:trip_page, first}))
    view |> element("button", "Refresh trips") |> render_click()
    assert has_element?(view, ".trip-timeline")

    view |> element("button", "Export this event page (JSON)") |> render_click()
    assert_push_event(view, "download-trip-page", %{"content" => page_json})
    page_export = Jason.decode!(page_json)
    assert page_export["page_count"] == 3
    assert page_export["has_more"] == true
    refute Map.has_key?(page_export, "cursor")

    Agent.update(c.faults, &Map.put(&1, :thing_trips, {:deny, "forbidden"}))
    view |> element("button", "Export this event page (JSON)") |> render_click()
    refute has_element?(view, "#trip-page-size")
    refute has_element?(view, ".trip-timeline")
    assert has_element?(view, "[role=alert]", "does not permit")
  end

  test "trip history distinguishes an unprovisioned asset from a missing one", c do
    {thing, _} = enrolled(c)
    {:ok, unprovisioned, _} = live(c.conn, Presenter.path(:asset, thing) <> "/trips")
    assert has_element?(unprovisioned, ".notice", "Provision this asset's Thing")
    refute has_element?(unprovisioned, "#trip-page-size")
    render_click(unprovisioned, "export-page", %{})
    assert has_element?(unprovisioned, "[role=alert]", "Check the required fields")

    {:ok, missing, _} =
      live(c.conn, Presenter.path(:asset, "urn:uuid:" <> Identifier.uuid()) <> "/trips")

    assert has_element?(missing, "[role=alert]", "requested record is not available")
    refute has_element?(missing, "#trip-page-size")
  end

  test "completed trip summaries stay gap-honest and reauthorize export", c do
    thing = provisioned(c)
    page = trip_page(thing, c.now - 10_000, nil, "10")
    summary = trip_summary(thing, "trip-one", c.now)
    Agent.update(c.faults, &Map.put(&1, :thing_trips, {:trip_page, page}))

    {:ok, trips, _} = live(c.conn, Presenter.path(:asset, thing) <> "/trips")
    path = Presenter.trip_summary_path(thing, "trip-one")
    assert has_element?(trips, ~s(a[href="#{path}"]), "Inspect final distance summary")
    refute has_element?(trips, ~s(a[href="#{Presenter.trip_summary_path(thing, "trip-two")}"]))

    Agent.update(c.faults, &Map.put(&1, :trip_summary, {:trip_summary, summary}))
    {:ok, view, html} = live(c.conn, path)
    render_patch(view, path)
    assert html =~ "Workshop sensor trip distance"
    assert has_element?(view, "h2", "Final distance summary")
    assert has_element?(view, ".reading", "120.5 m")
    assert render(view) =~ "Partial total: 1 adjacent segment(s) were excluded explicitly"
    assert render(view) =~ "Included · moving"
    assert render(view) =~ "Excluded · stationary"
    assert render(view) =~ "110.0 m–131.0 m"
    refute render(view) =~ "private-evidence"

    view |> element("button", "Export this final summary (JSON)") |> render_click()
    assert_push_event(view, "download-trip-summary", %{"content" => json})
    export = Jason.decode!(json)
    assert export["schema"] == "wtr.trip-summary-export.v1"
    assert export["thing_id"] == thing
    assert export["trip_id"] == "trip-one"
    assert export["summary_identity"] == summary["identity"]
    assert export["summary"] == summary

    assert export["presentation"] == %{
             "timezone_key" => "utc",
             "timezone" => "UTC",
             "fixed_offset_minutes" => 0,
             "distance_unit" => "metres",
             "distance_conversion" => "canonical_metres",
             "display_rounding" => "none"
           }

    refute json =~ "private-evidence"
    refute json =~ "wtrc1."

    view
    |> form("#trip-summary-presentation",
      summary: %{timezone: "utc_plus_02", distance_unit: "kilometres"}
    )
    |> render_submit()

    assert has_element?(view, ".reading", "0.121 km")
    assert render(view) =~ "0.11 km–0.131 km"
    assert render(view) =~ "UTC+02:00 fixed"
    assert render(view) =~ "fixed offsets do not follow"
    assert render(view) =~ "daylight-saving changes"
    assert render(view) =~ "Canonical service total: 120.5 m"

    view |> element("button", "Export this final summary (JSON)") |> render_click()
    assert_push_event(view, "download-trip-summary", %{"content" => selected_json})
    selected_export = Jason.decode!(selected_json)

    assert selected_export["presentation"] == %{
             "timezone_key" => "utc_plus_02",
             "timezone" => "UTC+02:00 fixed",
             "fixed_offset_minutes" => 120,
             "distance_unit" => "kilometres",
             "distance_conversion" => "metres_divided_by_1000",
             "display_rounding" => "three_decimal_places_display_only"
           }

    view
    |> form("#trip-summary-presentation",
      summary: %{timezone: "utc_minus_08", distance_unit: "miles"}
    )
    |> render_submit()

    assert has_element?(view, ".reading", "0.075 mi")
    assert render(view) =~ "UTC-08:00 fixed"

    view |> element("button", "Export this final summary (JSON)") |> render_click()
    assert_push_event(view, "download-trip-summary", %{"content" => miles_json})

    assert Jason.decode!(miles_json)["presentation"]["distance_conversion"] ==
             "international_mile_1609.344_metres"

    render_submit(view, "set-presentation", %{
      "summary" => %{"timezone" => "Europe/Stockholm", "distance_unit" => "nautical_miles"}
    })

    assert has_element?(view, "[role=alert]", "Check the required fields")
    assert has_element?(view, ".reading", "0.075 mi")
    render_submit(view, "set-presentation", %{})
    assert has_element?(view, "[role=alert]", "Check the required fields")

    view
    |> form("#trip-summary-presentation",
      summary: %{timezone: "utc", distance_unit: "metres"}
    )
    |> render_submit()

    Agent.update(c.faults, &Map.put(&1, :trip_summary, :unavailable))
    view |> element("button", "Export this final summary (JSON)") |> render_click()
    refute_push_event(view, "download-trip-summary", %{"content" => _})
    assert has_element?(view, "h2", "Final distance summary")

    Agent.update(c.faults, &Map.put(&1, :trip_summary, :unavailable))
    view |> element("button", "Refresh summary") |> render_click()
    assert has_element?(view, "h2", "Final distance summary")
    assert has_element?(view, "[role=alert]", "service could not complete")

    Agent.update(
      c.faults,
      &Map.put(&1, :trip_summary, {:reply, {:error, %{"code" => "unavailable"}}})
    )

    view |> element("button", "Refresh summary") |> render_click()
    refute has_element?(view, "h2", "Final distance summary")
    assert has_element?(view, "[role=alert]", "cannot be reconstructed")

    complete_segment =
      summary["segments"]
      |> hd()
      |> Map.merge(%{
        "center_distance_m" => 120,
        "lower_distance_m" => 110,
        "upper_distance_m" => 131
      })

    complete =
      Map.merge(summary, %{
        "terminal_kind" => "trip.interrupted",
        "terminal_reason" => "time_gap_exceeded",
        "status" => "complete",
        "reason" => "all_segments_included",
        "sample_count" => 2,
        "included_segment_count" => 1,
        "excluded_segment_count" => 0,
        "center_distance_m" => 120,
        "lower_distance_m" => 110,
        "upper_distance_m" => 131,
        "segments" => [complete_segment]
      })

    Agent.update(c.faults, &Map.put(&1, :trip_summary, {:trip_summary, complete}))
    view |> element("button", "Refresh summary") |> render_click()
    assert render(view) =~ "Every adjacent segment qualified and was included"
    assert render(view) =~ "Trip interrupted"
    assert has_element?(view, ".reading", "120 m")

    Agent.update(c.faults, &Map.put(&1, :trip_summary, {:trip_summary, summary}))
    view |> element("button", "Refresh summary") |> render_click()

    for invalid <- [
          %{},
          put_in(
            summary,
            ["segments", Access.at(0), "from_position_evidence_id"],
            "private-evidence"
          ),
          put_in(summary, ["included_segment_count"], 2),
          put_in(summary, ["center_distance_m"], 999.0),
          put_in(summary, ["lower_distance_m"], 109.0),
          put_in(summary, ["identity"], "invalid"),
          put_in(summary, ["started_at"], "invalid"),
          put_in(summary, ["status"], "complete"),
          put_in(summary, ["segments", Access.at(0)], %{}),
          put_in(summary, ["segments", Access.at(0), "center_distance_m"], nil)
        ] do
      Agent.update(c.faults, &Map.put(&1, :trip_summary, {:reply, {:ok, invalid}}))
      view |> element("button", "Refresh summary") |> render_click()
      refute has_element?(view, "h2", "Final distance summary")
      assert has_element?(view, "[role=alert]")

      Agent.update(c.faults, &Map.put(&1, :trip_summary, {:trip_summary, summary}))
      view |> element("button", "Refresh summary") |> render_click()
      assert has_element?(view, "h2", "Final distance summary")
    end

    changed = %{
      summary
      | "identity" => "wtr-trip-summary-v1:sha256:" <> String.duplicate("b", 64)
    }

    Agent.update(c.faults, &Map.put(&1, :trip_summary, {:reply, {:ok, changed}}))
    view |> element("button", "Export this final summary (JSON)") |> render_click()
    refute_push_event(view, "download-trip-summary", %{"content" => _})
    refute has_element?(view, "h2", "Final distance summary")
    assert has_element?(view, "[role=alert]", "service changed")

    Agent.update(
      c.faults,
      &Map.put(&1, :trip_summary, {:reply, {:error, %{"code" => "capacity_exceeded"}}})
    )

    view |> element("button", "Refresh summary") |> render_click()
    assert has_element?(view, "[role=alert]", "more than 100 retained samples")

    Agent.update(
      c.faults,
      &Map.put(&1, :trip_summary, {:reply, {:error, %{"code" => "not_found"}}})
    )

    view |> element("button", "Refresh summary") |> render_click()
    assert has_element?(view, "[role=alert]", "requested record is not available")

    render_click(view, "unknown-event", %{})
    render_click(view, "export", %{})
    assert has_element?(view, "[role=alert]", "Check the required fields")

    Agent.update(c.faults, &Map.put(&1, :get, {:reply, {:ok, %{}}}))
    {:ok, malformed_asset, _} = live(c.conn, Presenter.trip_summary_path(thing, "other-trip"))
    assert has_element?(malformed_asset, "[role=alert]")

    Agent.update(c.faults, &Map.put(&1, :get, {:deny, "forbidden"}))

    {:ok, _denied_asset, denied_html} =
      live(c.conn, Presenter.trip_summary_path(thing, "denied-trip"))

    assert denied_html =~ ~s(role="alert")

    Agent.update(c.faults, &Map.put(&1, :get, :unavailable))

    {:ok, _unavailable_asset, unavailable_html} =
      live(c.conn, Presenter.trip_summary_path(thing, "retry-trip"))

    assert unavailable_html =~ ~s(role="alert")

    Agent.update(c.faults, &Map.put(&1, :trip_summary, {:trip_summary, summary}))
    view |> element("button", "Refresh summary") |> render_click()
    Agent.update(c.faults, &Map.put(&1, :trip_summary, {:deny, "forbidden"}))
    view |> element("button", "Export this final summary (JSON)") |> render_click()
    refute has_element?(view, "h2", "Final distance summary")
    assert has_element?(view, "[role=alert]", "does not permit")
  end

  defp provisioned(c) do
    {thing, _} = enrolled(c)
    materialize(c, thing, "2")
    thing
  end

  defp trip_page(thing, now, cursor, generation, mode \\ :full) do
    items =
      if mode == :single do
        [trip_row(thing, "trip-page-two", "trip.started", "trip-two", now, now + 1_000)]
      else
        [
          trip_row(
            thing,
            "trip-page-one-stop",
            "trip.stopped",
            "trip-one",
            now + 5_500,
            now + 6_000
          ),
          trip_row(
            thing,
            "trip-page-one-start",
            "trip.started",
            "trip-one",
            now + 1_000,
            now + 2_000
          ),
          trip_row(
            thing,
            "trip-page-one-interrupted",
            "trip.interrupted",
            "trip-orphan",
            now + 7_000,
            now + 8_000
          )
        ]
      end

    page = %{
      "items" => items,
      "generation" => generation,
      "cursor" => cursor,
      "stream_cursor" => "stream-#{generation}"
    }

    if mode == :full,
      do: put_in(page, ["items", Access.at(2), "value", "mode"], "replay"),
      else: page
  end

  defp trip_row(thing, id, kind, trip, effective_at, confirmed_at) do
    reason =
      case kind do
        "trip.started" -> "movement_dwell_met"
        "trip.stopped" -> "stop_dwell_met"
        "trip.interrupted" -> "time_gap_exceeded"
      end

    %{
      "id" => id,
      "generation" => "10",
      "value" => %{
        "schema" => "wtr.alert.v1",
        "id" => id,
        "event_id" => id <> "-event",
        "event" => %{
          "schema" => "wtr.trip-event.v1",
          "id" => id <> "-event",
          "kind" => kind,
          "reason" => reason,
          "trip_id" => trip,
          "rule_id" => "movement",
          "rule_revision" => "7",
          "effective_at" => effective_at,
          "confirmed_at" => confirmed_at
        },
        "rule" => %{"kind" => "motion", "id" => "movement"},
        "thing_id" => thing,
        "mode" => "live",
        "physical_action_dispatch" => "separate_authorization_required",
        "created_at" => confirmed_at,
        "generation" => "10",
        "acknowledgement" => nil
      }
    }
  end

  defp trip_summary(thing, trip, now) do
    included = %{
      "schema" => "wtr.trip-distance-segment.v1",
      "event_at" => now - 9_000,
      "status" => "moving",
      "reason" => "distance_above_moving_threshold",
      "included" => true,
      "center_distance_m" => 120.5,
      "lower_distance_m" => 110.0,
      "upper_distance_m" => 131.0
    }

    excluded = %{
      "schema" => "wtr.trip-distance-segment.v1",
      "event_at" => now - 5_000,
      "status" => "stationary",
      "reason" => "below_stationary_threshold",
      "included" => false,
      "center_distance_m" => nil,
      "lower_distance_m" => nil,
      "upper_distance_m" => nil
    }

    %{
      "schema" => "wtr.trip-summary.v1",
      "algorithm" => "ordered-moving-segment-sum-v1",
      "thing_id" => thing,
      "trip_id" => trip,
      "snapshot_generation" => "16",
      "terminal_kind" => "trip.stopped",
      "terminal_reason" => "stop_dwell_met",
      "started_at" => now - 10_000,
      "confirmed_moving_at" => now - 9_000,
      "ended_at" => now - 5_000,
      "confirmed_ended_at" => now - 4_000,
      "status" => "partial",
      "reason" => "segments_excluded",
      "sample_count" => 3,
      "included_segment_count" => 1,
      "excluded_segment_count" => 1,
      "center_distance_m" => 120.5,
      "lower_distance_m" => 110.0,
      "upper_distance_m" => 131.0,
      "segments" => [included, excluded],
      "rule_revision" => "4",
      "identity" => "wtr-trip-summary-v1:sha256:" <> String.duplicate("a", 64)
    }
  end

  defp trip_iso(value) do
    value
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.to_iso8601()
  end

  defp materialize(c, thing, generation) do
    {:ok, _} =
      Service.materialize(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        %{"thing_id" => thing, "expected_generation" => generation},
        c.now
      )
  end

  defp operation_from(path),
    do: path |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("operation")

  defp battery_rule(thing, generation, {low, clear}),
    do: %{
      "id" => "low-battery",
      "kind" => "battery",
      "thing_id" => thing,
      "parameters" => %{
        "measurement_kind" => "batteryVoltage",
        "unit" => "V",
        "low_threshold" => low,
        "clear_threshold" => clear,
        "maximum_age_ms" => 86_400_000,
        "future_skew_ms" => 60_000,
        "accept_suspect" => false
      },
      "expected_generation" => generation
    }

  defp motion_rule(thing, generation),
    do: %{
      "id" => "motion-protection",
      "kind" => "motion",
      "thing_id" => thing,
      "parameters" => %{
        "event_time" => "trusted_fix",
        "future_skew_ms" => 1_000,
        "late_window_ms" => 10_000,
        "sequence" => "none",
        "moving_speed_m_s" => 1.5,
        "stationary_speed_m_s" => 0.2,
        "moving_distance_m" => 5,
        "stationary_distance_m" => 1,
        "max_plausible_speed_m_s" => 100,
        "max_gap_ms" => 300_000,
        "uncertainty" => "require_bound",
        "minimum_movement_ms" => 30_000,
        "minimum_stop_ms" => 60_000
      },
      "expected_generation" => generation
    }

  defp prepared_arming_view(c, path) do
    {:ok, view, _} = live(c.conn, path)
    render_click(view, "prepare", %{"status" => "armed"})
    {:ok, view, assert_patch(view)}
  end

  defp confirm_arming(view) do
    view
    |> form("#arming-confirmation", arming: %{confirmed: "yes"})
    |> render_submit()
  end

  defp invalid_arming(thing, revision),
    do: %{
      "value" => %{
        "schema" => "wtr.arming.v1",
        "thing_id" => thing,
        "status" => "armed",
        "revision" => revision,
        "changed_at" => 0,
        "changed_by" => "wtr1_actor"
      }
    }

  defp generation(c) do
    {:ok, %{"generation" => generation}} =
      Service.list(c.service, c.admin, c.scope, "enrollments", %{"limit" => 1}, c.now)

    generation
  end

  # Commits one unrelated observation so a following view sees a new scope event.
  defp commit_change(c, id) do
    {:ok, %{"generation" => generation}} =
      Service.list(c.service, c.admin, c.scope, "observations", %{"limit" => 1}, c.now)

    {:ok, %{"outcome" => "committed"}} =
      Service.submit(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        import_request(%{id: "observation-" <> id}, generation),
        c.now
      )
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

  defp append_history_state(c, thing, state, access, step) do
    {:ok, update} =
      Update.new(%{
        principal: access.principal,
        scope: c.scope,
        authority: access,
        operation_id: Identifier.uuid(),
        expected_generation: Integer.to_string(step + 2),
        request: %{"operation" => "history-fixture", "step" => step},
        now: c.now,
        observation: nil,
        records: [
          %{
            kind: "state",
            id: thing,
            value: %{
              "public" => Map.put(state, "observed_at", Projection.scalar(c.now + step * 1_000))
            }
          }
        ],
        events: [],
        publication: nil
      })

    assert {:ok, _} = Store.mutate(c.store, update)
  end

  defp public_position(now),
    do: %{
      "schema" => "wtr.position-public.v1",
      "latitude" => Projection.scalar(59.3293),
      "longitude" => Projection.scalar(18.0686),
      "altitude_m" => Projection.scalar(nil),
      "speed_m_s" => Projection.scalar(0.0),
      "horizontal_accuracy_m" => Projection.scalar(5.0),
      "accuracy_kind" => "bound",
      "source" => "gnss",
      "fix_at" => Projection.scalar(now),
      "received_at" => Projection.scalar(now),
      "fix_clock" => "trusted",
      "availability" => "available",
      "quality" => "valid"
    }

  defp route_page(thing, now, cursor, identity) do
    first = route_point("wtr1_point-a", now, 10.0, 179.9, "valid")
    second = route_point("wtr1_point-b", now + 1_000, 10.1, -179.9, "valid")
    third = route_point("wtr1_point-c", now + 3_000, 10.2, -179.8, "valid")

    {segments, breaks, rejected, excluded, status, reason, record_count, sample_count,
     point_count, segment_count, after_generation,
     history_count} =
      if cursor do
        {
          [
            %{
              "schema" => "wtr.route-segment-public.v1",
              "point_count" => 2,
              "points" => [first, second]
            },
            %{
              "schema" => "wtr.route-segment-public.v1",
              "point_count" => 1,
              "points" => [third]
            }
          ],
          Enum.map(
            ~w(unqualified_materialisations rejected_samples time_gap distance_gap time_and_distance_gap),
            &route_break(first, third, &1)
          ),
          [
            %{
              "schema" => "wtr.route-rejection-public.v1",
              "id" => "wtr1_rejected",
              "received_at" => Projection.scalar(now + 500),
              "reason" => "quality:suspect"
            }
          ],
          [
            %{
              "schema" => "wtr.route-exclusion.v1",
              "id" => "wtr1_excluded",
              "received_at" => Projection.scalar(now + 2_000),
              "reason" => "ambiguous_positions"
            }
          ],
          "partial",
          "gaps_or_rejections",
          5,
          4,
          3,
          2,
          "0",
          3
        }
      else
        {
          [
            %{
              "schema" => "wtr.route-segment-public.v1",
              "point_count" => 1,
              "points" => [third]
            }
          ],
          [],
          [],
          [],
          "complete",
          "all_positions_qualified",
          1,
          1,
          1,
          1,
          "2",
          1
        }
      end

    %{
      "schema" => "wtr.route-page.v1",
      "algorithm" => "snapshot-pinned-gap-honest-route-v1",
      "thing_id" => thing,
      "generation" => "3",
      "history" => %{
        "after_generation" => after_generation,
        "last_generation" => "3",
        "record_count" => history_count
      },
      "window" => %{"from_at" => now - 86_400_000, "to_at" => now + 10_000},
      "continuity" => "page_local_only",
      "route" => %{
        "schema" => "wtr.route-replay-public.v1",
        "algorithm" => "snapshot-pinned-gap-honest-route-v1",
        "status" => status,
        "reason" => reason,
        "record_count" => record_count,
        "sample_count" => sample_count,
        "point_count" => point_count,
        "segment_count" => segment_count,
        "break_count" => length(breaks),
        "rejected_count" => length(rejected),
        "excluded_count" => length(excluded),
        "segments" => segments,
        "breaks" => breaks,
        "rejected" => rejected,
        "excluded" => excluded,
        "policy" => %{},
        "window" => %{"from_at" => now - 86_400_000, "to_at" => now + 10_000}
      },
      "cursor" => cursor,
      "identity" => identity
    }
  end

  defp route_point(id, event_at, latitude, longitude, quality),
    do: %{
      "schema" => "wtr.route-point-public.v1",
      "id" => id,
      "latitude" => Projection.scalar(latitude),
      "longitude" => Projection.scalar(longitude),
      "horizontal_accuracy_m" => Projection.scalar(5.0),
      "accuracy_kind" => "bound",
      "source" => "gnss",
      "quality" => quality,
      "event_at" => Projection.scalar(event_at),
      "event_time_basis" => "trusted_fix",
      "received_at" => Projection.scalar(event_at)
    }

  defp route_break(first, third, reason),
    do: %{
      "schema" => "wtr.route-break-public.v1",
      "after_point_id" => first["id"],
      "before_point_id" => third["id"],
      "after_event_at" => first["event_at"],
      "before_event_at" => third["event_at"],
      "gap_ms" => Projection.scalar(2_000),
      "center_distance_m" => Projection.scalar(22_000.0),
      "reason" => reason,
      "excluded_ids" =>
        if(reason == "unqualified_materialisations", do: ["wtr1_excluded"], else: []),
      "rejected_ids" => if(reason == "rejected_samples", do: ["wtr1_rejected"], else: [])
    }

  defp owner_presence_fact(thing, label, status, observed_at) do
    observation_id = "presence-observation-ui-" <> label
    evidence_id = "presence-evidence-ui-" <> label

    {:ok, observation} =
      Observation.new(%{
        id: observation_id,
        observed_at: observed_at,
        ingress: "imported",
        source: %{"kind" => "qualified-owner-presence"},
        addressing: %{"thing_id" => thing},
        payload: {:json, %{"predicate" => "owner.present", "status" => status}},
        radio: %{},
        transport: %{},
        provenance: %{"kind" => "ui-test-presence-source"}
      })

    {:ok, evidence} =
      Evidence.new(%{
        id: evidence_id,
        kind: :identity,
        claim: %{
          "schema" => "wtr.policy-fact.v1",
          "predicate" => "owner.present",
          "status" => status,
          "policy_revision" => "ui-presence-source-v1",
          "reason" => "qualified_observation"
        },
        source_observation_ids: [observation_id],
        evidence_ids: [],
        profile: {"ui-test-presence", "1"},
        decoder: {"ui-test-presence", "1"},
        confidence: :exact,
        reasons: ["qualified_observation"],
        association_id: thing
      })

    {:ok, bundle} = EvidenceBundle.new([observation], [evidence])
    {:ok, fact} = PolicyFact.new(evidence_id, bundle)
    {:ok, document} = PolicyFact.to_map(fact)
    document
  end

  defp suspicious_alert(interpretation, now),
    do: %{
      "schema" => "wtr.alert.v1",
      "id" => "suspicious-alert",
      "event_id" => "suspicious-event",
      "event" => %{
        "schema" => "wtr.suspicious-movement-event.v1",
        "id" => "suspicious-event",
        "kind" => "suspicious_movement",
        "rule_id" => "suspicious-rule",
        "rule_revision" => "7",
        "active_trip_id" => "active-trip",
        "owner_unknown_interpretation" => interpretation
      },
      "rule" => %{"kind" => "suspicious_movement", "id" => "suspicious-rule"},
      "thing_id" => "urn:uuid:123e4567-e89b-42d3-a456-426614174000",
      "mode" => "live",
      "physical_action_dispatch" => "separate_authorization_required",
      "created_at" => now,
      "generation" => "7",
      "acknowledgement" => nil
    }

  defp dashboard_query(thing, now) do
    {:ok, spec} =
      QuerySpec.new(%{
        id: "browser-saved-temperature",
        revision: "service-query-v1",
        dataset: :measurements,
        measurement: "temperature",
        unit: "Cel",
        series: List.wrap(thing),
        qualities: [:valid],
        from_at: now - 3_600_000,
        to_at: now + 1,
        timezone: "Etc/UTC",
        bucket_ms: 3_600_000,
        aggregation: :mean,
        order: :ascending,
        max_points: 2
      })

    {:ok, document} = QuerySpec.to_map(spec)
    document
  end

  defp saved_dashboard(c, series \\ "workshop-asset") do
    id = "workshop-dashboard"
    {:ok, page} = Service.list(c.service, c.admin, c.scope, "saved_queries", %{}, c.now)
    operation = Identifier.uuid()

    {:ok, _} =
      Service.save_query(
        c.service,
        c.admin,
        c.scope,
        operation,
        dashboard_request(id, "Workshop dashboard", c, page["generation"], series),
        c.now
      )

    {id, operation}
  end

  defp dashboard_request(id, title, c, generation, series \\ "workshop-asset") do
    query = dashboard_query(series, c.now)

    %{
      "id" => id,
      "title" => title,
      "query" => query,
      "window" => %{"kind" => "rolling", "duration_ms" => query["to_at"] - query["from_at"]},
      "visualization" => %{"type" => "line", "show_legend" => true, "show_points" => true},
      "expected_generation" => generation
    }
  end

  defp comparison_sources(c, second_window \\ :rolling) do
    {first, operation} = saved_dashboard(c)
    second = "another-dashboard"
    {:ok, page} = Service.list(c.service, c.admin, c.scope, "saved_queries", %{}, c.now)

    request =
      dashboard_request(second, "Another dashboard", c, page["generation"], "another-asset")

    request =
      if second_window == :absolute_second, do: Map.delete(request, "window"), else: request

    {:ok, _} =
      Service.save_query(c.service, c.admin, c.scope, Identifier.uuid(), request, c.now)

    {first, second, operation}
  end
end
