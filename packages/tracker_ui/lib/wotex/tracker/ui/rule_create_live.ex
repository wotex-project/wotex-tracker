defmodule Wotex.Tracker.UI.RuleCreateLive do
  @moduledoc """
  Lists one provisioned asset's rule definitions and lets an administrator add one.

  The page reads the asset's live definitions at one committed snapshot under
  current `read` authority and links each to its rule status. A Thing admits at
  most eight definitions, so a full asset offers no new rule.

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

  @impl true
  def mount(_, _, socket),
    do:
      {:ok,
       assign(socket,
         id: nil,
         asset: nil,
         thing: nil,
         definitions: nil,
         maximum: @maximum_definitions,
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
                <th scope="col">Rule</th><th scope="col">Revision</th><th scope="col">Settings</th>
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
          </fieldset>
          <RuleForm.fields heartbeat={true} battery={RuleForm.battery?(@thing)} />
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
        assign(socket, definitions: Enum.map(items, & &1["value"]))

      {:error, error} ->
        assign(socket, definitions: nil, error: error)
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

    with true <- kind == "heartbeat" or RuleForm.battery?(socket.assigns.thing),
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
