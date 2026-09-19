defmodule Wotex.Tracker.UI.RuleCreateLive do
  @moduledoc """
  Lists one provisioned asset's rule definitions and lets an administrator add one.

  The page reads the asset's live definitions at one committed snapshot under
  current `read` authority and links each to its rule status. A Thing admits at
  most eight definitions, so a full asset offers no new rule. The page also pages
  the alerts recorded for those definitions, newest first, with a bounded path back
  through earlier pages.

  Preparing a rule captures the current scope generation and puts a fresh
  operation reference in the page address. The rule ID is derived from that
  reference, so a lost reply can be verified without submitting again. The
  service validates, stores and evaluates the definition; this page sends no
  notification and requests no physical Action.
  """

  use Phoenix.LiveView, log: false
  import Wotex.Tracker.UI.Components
  alias Wotex.Tracker.Service.Identifier
  alias Wotex.Tracker.UI.{Auth, Presenter, RuleForm}

  # HTTP contract 1.12.0 admits at most eight live definitions per Thing.
  @maximum_definitions 8
  @alert_page_size 10
  @alert_back_limit 32

  @impl true
  def mount(_, _, socket),
    do:
      {:ok,
       assign(socket,
         id: nil,
         asset: nil,
         thing: nil,
         definitions: nil,
         statuses: nil,
         maximum: @maximum_definitions,
         alerts: nil,
         alert_params: nil,
         alert_back: [],
         alerts_error: nil,
         operation: nil,
         generation: nil,
         outcome: nil,
         saved: nil,
         error: nil
       )}

  @impl true
  def handle_params(%{"id" => id} = params, _, socket) do
    socket =
      if socket.assigns.id == id,
        do: socket,
        else: assign(socket, id: id, generation: nil)

    {:noreply, socket |> load() |> activate(params["operation"]) |> recover()}
  end

  @impl true
  def handle_event(
        "prepare",
        _,
        %{
          assigns: %{
            operation: nil,
            thing: %{},
            definitions: definitions,
            identity: %{"can_manage_queries" => true}
          }
        } = socket
      )
      when is_list(definitions) and length(definitions) < @maximum_definitions do
    case Auth.request(socket, :list, %{"resource" => "policies", "params" => %{"limit" => 1}}) do
      {:ok, %{"generation" => generation}} ->
        socket = assign(socket, generation: generation, error: nil)

        {:noreply,
         push_patch(socket,
           to:
             Presenter.path(:asset, socket.assigns.id) <>
               "/protection?operation=" <> Identifier.uuid()
         )}

      {:error, error} ->
        {:noreply, assign(socket, error: error)}
    end
  end

  def handle_event(
        "prepare",
        _,
        %{
          assigns: %{
            operation: nil,
            thing: %{},
            definitions: definitions,
            identity: %{"can_manage_queries" => true}
          }
        } = socket
      )
      when is_list(definitions),
      do: {:noreply, assign(socket, error: %{"code" => "capacity_exceeded"})}

  def handle_event("prepare", _, socket),
    do: {:noreply, assign(socket, error: %{"code" => "forbidden"})}

  def handle_event(
        "save",
        %{"rule" => input},
        %{
          assigns: %{
            operation: operation,
            generation: generation,
            outcome: nil,
            thing: %{},
            identity: %{"can_manage_queries" => true}
          }
        } = socket
      )
      when is_binary(operation) and is_binary(generation) do
    case request(socket, input) do
      {:ok, request} ->
        result =
          Auth.request(socket, :save_policy, %{"operation" => operation, "request" => request})

        {:noreply, result(socket, result)}

      :error ->
        {:noreply, assign(socket, error: %{"code" => "invalid_request"})}
    end
  end

  def handle_event("save", _, socket),
    do:
      {:noreply,
       if(socket.assigns.outcome,
         do: socket,
         else: assign(socket, error: %{"code" => "forbidden"})
       )}

  def handle_event("check-operation", _, socket), do: {:noreply, recover(socket)}
  def handle_event("refresh", _, socket), do: {:noreply, load(socket)}

  def handle_event("next-alerts", _, %{assigns: %{alerts: %{"cursor" => cursor}}} = socket)
      when is_binary(cursor) do
    next = alerts(socket, %{"cursor" => cursor})

    if next.assigns.alert_params == %{"cursor" => cursor} do
      back = [socket.assigns.alert_params | socket.assigns.alert_back]
      {:noreply, assign(next, alert_back: Enum.take(back, @alert_back_limit))}
    else
      {:noreply, next}
    end
  end

  def handle_event("previous-alerts", _, %{assigns: %{alert_back: [params | rest]}} = socket) do
    previous = alerts(socket, params)

    cond do
      previous.assigns.alert_params != params ->
        {:noreply, previous}

      previous.assigns.alerts["generation"] != socket.assigns.alerts["generation"] ->
        {:noreply, assign(socket, alerts_error: %{"code" => "conflict"})}

      true ->
        {:noreply, assign(previous, alert_back: rest)}
    end
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <main id="main" class="workspace narrow">
      <a href={Presenter.path(:asset, @id)}>← Asset details</a>
      <p class="eyebrow">Protection</p>
      <div class="heading">
        <h1>{if @asset, do: "Rules for #{@asset["title"]}", else: "Asset unavailable"}</h1>
        <button class="secondary" phx-click="refresh">Refresh</button>
      </div>
      <p>
        The service evaluates a rule from this asset's committed evidence when it is saved and
        whenever the asset is provisioned again. Alerts are recorded, not sent, and no physical
        Action is requested.
      </p>
      <.notice error={@error} />
      <p :if={@asset && is_nil(@thing)}>
        Provision this asset before adding a rule; rules need its committed evidence.
      </p>
      <section :if={@thing} class="panel" aria-labelledby="asset-rules-title">
        <h2 id="asset-rules-title">Defined rules</h2>
        <p :if={is_nil(@definitions)} role="status">
          Defined rules are unavailable. Refresh to retry.
        </p>
        <p :if={@definitions == []}>No rules are defined for this asset.</p>
        <div
          :if={@definitions not in [nil, []]}
          class="table-scroll"
          tabindex="0"
          role="region"
          aria-labelledby="asset-rules-title"
        >
          <table>
            <caption>
              {length(@definitions)} of {@maximum} rule definitions for this asset
            </caption>
            <thead>
              <tr>
                <th scope="col">Rule</th><th scope="col">Status</th><th scope="col">Revision</th><th scope="col">
                  Settings
                </th>
              </tr>
            </thead>
            <tbody>
              <tr :for={definition <- @definitions}>
                <td>
                  <a href={Presenter.rule_path(definition["kind"] <> ":" <> definition["id"])}>
                    {Presenter.rule_kind(definition["kind"])}
                  </a>
                  <span class="identifier">{definition["id"]}</span>
                </td>
                <td>{status_label(@statuses, definition)}</td>
                <td>{definition["revision"]}</td>
                <td>{Presenter.rule_parameters(definition["kind"], definition["parameters"])}</td>
              </tr>
            </tbody>
          </table>
        </div>
        <p :if={is_list(@definitions) && length(@definitions) >= @maximum} role="status">
          This asset has the maximum of {@maximum} rule definitions. Delete one from its rule page
          before adding another.
        </p>
      </section>
      <section :if={@thing} class="panel" aria-labelledby="asset-alerts-title">
        <h2 id="asset-alerts-title">Alerts for this asset</h2>
        <p>
          Alerts recorded by this asset's defined rules, newest first. Alerts from host-managed rules
          appear only in the full alert list.
        </p>
        <.notice error={@alerts_error} />
        <p :if={is_nil(@alerts)} role="status">Alerts are unavailable. Refresh to retry.</p>
        <p :if={@alerts && @alerts["items"] == []}>No alerts on this page.</p>
        <div
          :if={@alerts && @alerts["items"] != []}
          class="table-scroll"
          tabindex="0"
          role="region"
          aria-labelledby="asset-alerts-title"
        >
          <table>
            <caption>Alerts at scope version {@alerts["generation"]}</caption>
            <thead>
              <tr>
                <th scope="col">Alert</th><th scope="col">Rule</th><th scope="col">Recorded</th><th scope="col">
                  Review
                </th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @alerts["items"]}>
                <td>
                  <a href={Presenter.alert_path(row["id"])}>
                    {Presenter.alert_kind(row["value"]["event"]["kind"])}
                  </a>
                </td>
                <td>{row["value"]["rule"]["id"]}</td>
                <td>{Presenter.timestamp(%{"value" => row["value"]["created_at"]})}</td>
                <td>{Presenter.alert_state(row["value"])}</td>
              </tr>
            </tbody>
          </table>
        </div>
        <button :if={@alert_back != []} class="secondary" phx-click="previous-alerts">
          Newer alerts
        </button>
        <button :if={@alerts && @alerts["cursor"]} class="secondary" phx-click="next-alerts">
          Older alerts
        </button>
        <a href="/protection/alerts">All alerts</a>
      </section>
      <section :if={@thing} class="panel" aria-labelledby="add-rule-title">
        <h2 id="add-rule-title">Add a rule</h2>
        <p :if={!@identity["can_manage_queries"]}>
          Your credential can inspect rule status but cannot add rules.
        </p>
        <button
          :if={
            @identity["can_manage_queries"] && is_nil(@operation) && is_list(@definitions) &&
              length(@definitions) < @maximum
          }
          phx-click="prepare"
        >Prepare rule</button>
        <.form
          :if={@identity["can_manage_queries"] && @operation && @generation && is_nil(@outcome)}
          for={%{}}
          id="rule-definition"
          phx-submit="save"
        >
          <fieldset>
            <legend>Rule</legend>
            <label>
              <input type="radio" name="rule[kind]" value="heartbeat" checked />
              Reporting heartbeat: alert when no newer capture is committed in time
            </label>
            <label :if={RuleForm.battery?(@thing)}>
              <input type="radio" name="rule[kind]" value="battery" />
              Low battery voltage, with separate low and recovery thresholds
            </label>
            <label>
              <input type="radio" name="rule[kind]" value="motion" />
              Motion and trips, confirmed from ordered position evidence
            </label>
            <label>
              <input type="radio" name="rule[kind]" value="geofence" />
              Geofence membership and entry or exit transitions
            </label>
          </fieldset>
          <p>
            Position rules evaluate only evidence bundles with exactly one position. Multiple
            sources remain unchanged until an explicit selection policy is configured through the
            service API.
          </p>
          <RuleForm.fields kinds={
            if RuleForm.battery?(@thing),
              do: ~w(heartbeat battery motion geofence),
              else: ~w(heartbeat motion geofence)
          } />
          <button type="submit" phx-disable-with="Saving…">Save rule</button>
        </.form>
      </section>
      <section :if={@operation} class="operation">
        <p :if={@outcome} role="status">
          {if @outcome["outcome"] == "committed", do: "Rule saved", else: "Rule outcome unknown"}
        </p>
        <a :if={@saved} href={Presenter.rule_path(@saved["kind"] <> ":" <> @saved["id"])}>
          Open rule status
        </a>
        <p :if={@outcome && @outcome["outcome"] != "committed"}>
          Keep this page's address and check the operation outcome before trying again.
        </p>
        <p class="identifier">Operation {@operation}</p>
        <button class="secondary" phx-click="check-operation">Check operation outcome</button>
      </section>
    </main>
    """
  end

  defp load(socket) do
    with {:ok, %{"value" => asset}} <-
           Auth.request(socket, :get, %{"resource" => "enrollments", "id" => socket.assigns.id}),
         {:ok, thing} <- thing(socket) do
      socket
      |> assign(asset: asset, thing: thing, error: nil)
      |> definitions()
      |> first_alerts()
    else
      {:error, error} -> assign(socket, asset: nil, thing: nil, definitions: nil, error: error)
    end
  end

  defp thing(socket) do
    case Auth.request(socket, :get, %{"resource" => "things", "id" => socket.assigns.id}) do
      {:ok, %{"value" => thing}} -> {:ok, thing}
      {:error, %{"code" => "not_found"}} -> {:ok, nil}
      error -> error
    end
  end

  defp definitions(%{assigns: %{thing: nil}} = socket), do: assign(socket, definitions: nil)

  # A failed read leaves the list unknown, so the page offers no rule it cannot count.
  defp definitions(socket) do
    case Auth.request(socket, :thing_policies, %{"thing" => socket.assigns.id}) do
      {:ok, %{"items" => items}} ->
        socket
        |> assign(definitions: Enum.map(items, & &1["value"]))
        |> statuses()

      {:error, error} ->
        assign(socket, definitions: nil, error: error)
    end
  end

  defp first_alerts(%{assigns: %{thing: nil}} = socket),
    do: assign(socket, alerts: nil, alert_params: nil, alert_back: [], alerts_error: nil)

  defp first_alerts(socket) do
    first = alerts(assign(socket, alerts: nil), %{"limit" => @alert_page_size})

    if first.assigns.alert_params == %{"limit" => @alert_page_size},
      do: assign(first, alert_back: []),
      else: first
  end

  # A failed page keeps the displayed page; an authority failure clears it.
  defp alerts(socket, params) do
    case Auth.request(socket, :thing_alerts, %{"thing" => socket.assigns.id, "params" => params}) do
      {:ok, %{"items" => items} = page} when is_list(items) ->
        assign(socket, alerts: page, alert_params: params, alerts_error: nil)

      {:error, %{"code" => code} = error} when code in ~w(forbidden unauthorized) ->
        assign(socket, alerts: nil, alert_params: nil, alert_back: [], alerts_error: error)

      {:error, error} ->
        assign(socket, alerts_error: error)

      _ ->
        assign(socket, alerts_error: %{"code" => "storage_unavailable"})
    end
  end

  # Status is read separately, so a failed read leaves definitions visible.
  defp statuses(socket) do
    case Auth.request(socket, :thing_rules, %{"thing" => socket.assigns.id}) do
      {:ok, %{"items" => items}} when is_list(items) ->
        assign(socket, statuses: Map.new(items, &{&1["id"], &1["value"]}))

      _ ->
        assign(socket, statuses: nil)
    end
  end

  defp status_label(nil, _), do: "Unavailable"

  defp status_label(statuses, definition) do
    case statuses[definition["kind"] <> ":" <> definition["id"]] do
      %{"status" => status} -> Presenter.rule_status(status)
      _ -> "Not evaluated"
    end
  end

  defp activate(socket, nil),
    do: assign(socket, operation: nil, outcome: nil, saved: nil)

  defp activate(socket, operation) do
    cond do
      not Identifier.operation?(operation) ->
        assign(socket, operation: nil, error: %{"code" => "invalid_request"})

      socket.assigns.operation == operation ->
        socket

      true ->
        assign(socket, operation: operation, outcome: nil, saved: nil)
        |> current_generation()
    end
  end

  # A reconnect without a prepared generation reads the current one before showing the form.
  defp current_generation(%{assigns: %{generation: generation}} = socket)
       when is_binary(generation),
       do: socket

  defp current_generation(socket) do
    case Auth.request(socket, :list, %{"resource" => "policies", "params" => %{"limit" => 1}}) do
      {:ok, %{"generation" => generation}} -> assign(socket, generation: generation)
      {:error, error} -> assign(socket, error: error)
    end
  end

  defp recover(%{assigns: %{operation: nil}} = socket), do: socket

  defp recover(socket) do
    case Auth.request(socket, :operation, %{"id" => socket.assigns.operation}) do
      {:error, %{"code" => "not_found"}} -> socket
      result -> result(socket, result)
    end
  end

  defp result(socket, {:ok, %{"outcome" => "committed", "data" => data} = receipt}) do
    id = rule_id(socket.assigns.operation)

    if data == %{"policy_id" => id, "action" => "saved"},
      do: verify(socket, id, receipt),
      else: unrelated(socket)
  end

  defp result(socket, {:ok, %{"outcome" => "unknown"} = receipt}),
    do: assign(socket, outcome: receipt, error: nil)

  defp result(socket, {:ok, _}), do: unrelated(socket)

  defp result(socket, {:error, %{"outcome" => "not_committed"} = error}),
    do: assign(socket, error: error)

  defp result(socket, {:error, error}),
    do: assign(socket, outcome: %{"outcome" => "unknown"}, error: error)

  defp verify(socket, id, receipt) do
    asset = socket.assigns.id

    case Auth.request(socket, :get, %{"resource" => "policies", "id" => id}) do
      {:ok, %{"value" => %{"thing_id" => ^asset} = saved}} ->
        socket
        |> assign(outcome: receipt, saved: saved, error: nil)
        |> definitions()

      {:error, error} ->
        assign(socket, outcome: %{"outcome" => "unknown"}, error: error)

      _ ->
        unrelated(socket)
    end
  end

  defp unrelated(socket),
    do:
      assign(socket,
        outcome: %{"outcome" => "unrelated"},
        saved: nil,
        error: %{"code" => "operation_mismatch"}
      )

  defp request(socket, input) do
    kind = input["kind"]

    with true <-
           kind in ~w(heartbeat motion geofence) or
             (kind == "battery" and RuleForm.battery?(socket.assigns.thing)),
         {:ok, parameters} <- RuleForm.parameters(kind, input) do
      {:ok,
       %{
         "id" => rule_id(socket.assigns.operation),
         "kind" => kind,
         "thing_id" => socket.assigns.id,
         "parameters" => parameters,
         "expected_generation" => socket.assigns.generation
       }}
    else
      _ -> :error
    end
  end

  defp rule_id(operation), do: "rule-" <> operation
end
