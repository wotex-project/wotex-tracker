defmodule Wotex.Tracker.UI.WorkflowTest do
  @moduledoc false
  use ExUnit.Case, async: false
  import Plug.Conn
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Wotex.Tracker.Service.Fixtures
  alias Phoenix.LiveView.Static
  alias Wotex.Tracker.{QueryResult, QuerySpec}
  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.{Codec, Identifier, Projection, Store, Update}
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

  test "host operational pages require admin authority and retain a pinned collector page", c do
    cursor = %{
      "schema" => "wtr.operational-cursor.v1",
      "epoch" => "collector-one",
      "after" => 1,
      "through" => 2,
      "event" => nil,
      "limit" => 25
    }

    first = %{
      "schema" => "wtr.operational-page.v1",
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
    assert has_element?(view, "button", "Next page")

    Agent.update(c.faults, &Map.put(&1, :operational_history, {:page, second}))
    view |> element("button", "Next page") |> render_click()
    assert render(view) =~ "render.stop"
    assert has_element?(view, "button", "Previous page")

    Agent.update(c.faults, &Map.put(&1, :operational_history, {:page, first}))
    view |> element("button", "Previous page") |> render_click()
    assert render(view) =~ "query.stop"

    Agent.update(c.faults, &Map.put(&1, :operational_history, :unavailable))
    view |> element("button", "Refresh") |> render_click()
    assert render(view) =~ "query.stop"
    assert has_element?(view, "[role=alert]")

    Agent.update(c.faults, &Map.put(&1, :operational_history, {:page, first}))
    view |> form("#operational-filter", filter: %{event: "query.stop"}) |> render_submit()
    assert has_element?(view, "#operational-event option[value='query.stop'][selected]")
    assert render(view) =~ "query.stop"

    Agent.update(c.faults, &Map.put(&1, :operational_history, {:page, %{"samples" => []}}))
    view |> element("button", "Refresh") |> render_click()
    refute has_element?(view, "tbody tr")
    assert has_element?(view, "[role=alert]")

    Agent.update(c.faults, &Map.put(&1, :operational_history, {:page, first}))
    view |> element("button", "Refresh") |> render_click()
    assert render(view) =~ "query.stop"

    render_hook(view, "filter", %{"filter" => %{"event" => "unknown"}})
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
    Agent.update(c.faults, &Map.put(&1, :analytics, {:deny, "forbidden"}))
    view |> element("button", "Export result JSON") |> render_click()
    refute_push_event(view, "download-query-result", %{"content" => _})
    refute has_element?(view, "h2", "Query result")
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

    Agent.update(c.faults, &Map.put(&1, :execute_saved_query, :unavailable))
    send(detail.pid, {:auto_refresh, 1})
    assert render(detail) =~ "displayed result is stale"
    assert render(detail) =~ "24.3"

    Agent.update(c.faults, &Map.put(&1, :get, :unavailable))
    send(detail.pid, {:auto_refresh, 1})
    assert render(detail) =~ "displayed result is stale"
    assert has_element?(detail, "circle.chart-point")

    send(detail.pid, {:auto_refresh, 1})
    assert render(detail) =~ "Auto-refresh active"
    refute render(detail) =~ "displayed result is stale"
    assert has_element?(detail, "button[phx-value-view='points'][aria-pressed='true']")

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
