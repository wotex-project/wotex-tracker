defmodule Wotex.Tracker.UI.RuleLive do
  @moduledoc """
  Shows one committed rule status, its definition and retained evaluation history.

  The current status and every history page come from the authorized service
  `rules` projection. History navigation keeps a bounded path through earlier
  pages and reloads each under current authority. Terminal denial or a missing
  rule clears the page; a temporary failure keeps the displayed status for retry.

  When the rule has a service definition, an administrator can prepare an edit
  or deletion. Preparation captures the scope generation and keeps an operation
  reference in the address, so a lost reply is resolved from its receipt rather
  than by submitting again.
  """

  use Phoenix.LiveView, log: false
  import Wotex.Tracker.UI.Components
  alias Wotex.Tracker.Service.Identifier
  alias Wotex.Tracker.UI.{Auth, Presenter, RuleForm}

  @history_back_limit 32

  @impl true
  def mount(_, _, socket),
    do:
      {:ok,
       assign(socket,
         id: nil,
         rule: nil,
         definition: nil,
         history: nil,
         history_params: nil,
         history_back: [],
         error: nil,
         manage_operation: nil,
         manage_intent: nil,
         manage_generation: nil,
         manage_outcome: nil,
         manage_error: nil
       )}

  @impl true
  def handle_params(%{"id" => id} = params, _, socket) do
    {:noreply,
     socket
     |> assign(id: id)
     |> load()
     |> activate_manage(params["manage_operation"], params["manage_intent"])
     |> recover_manage()
     |> load_manage_generation()}
  end

  @impl true
  def handle_event("refresh", _, socket), do: {:noreply, load(socket)}

  def handle_event("next-history", _, %{assigns: %{history: %{"cursor" => cursor}}} = socket)
      when is_binary(cursor) do
    next = history(socket, %{"cursor" => cursor})

    if next.assigns.history_params == %{"cursor" => cursor} do
      back = [socket.assigns.history_params | socket.assigns.history_back]
      {:noreply, assign(next, history_back: Enum.take(back, @history_back_limit))}
    else
      {:noreply, next}
    end
  end

  def handle_event("previous-history", _, %{assigns: %{history_back: [params | rest]}} = socket) do
    previous = history(socket, params)

    cond do
      previous.assigns.history_params != params ->
        {:noreply, previous}

      previous.assigns.history["generation"] != socket.assigns.history["generation"] ->
        {:noreply, assign(socket, error: %{"code" => "conflict"})}

      true ->
        {:noreply, assign(previous, history_back: rest)}
    end
  end

  def handle_event("prepare-manage", %{"intent" => intent}, socket)
      when intent in ~w(edit delete) do
    if can_prepare?(socket.assigns, intent) do
      case current_generation(socket) do
        {:ok, generation} ->
          {:noreply,
           socket
           |> assign(manage_generation: generation, manage_error: nil)
           |> push_patch(
             to:
               Presenter.rule_path(socket.assigns.id) <>
                 "?manage_operation=#{Identifier.uuid()}&manage_intent=#{intent}"
           )}

        {:error, error} ->
          {:noreply, assign(socket, manage_error: error)}
      end
    else
      {:noreply, assign(socket, manage_error: %{"code" => "forbidden"})}
    end
  end

  def handle_event("prepare-manage", _, socket),
    do: {:noreply, assign(socket, manage_error: %{"code" => "invalid_request"})}

  def handle_event("edit", %{"rule" => input}, socket) do
    definition = socket.assigns.definition

    with true <- manageable?(socket.assigns, "edit"),
         {:ok, parameters} <- RuleForm.parameters(definition["kind"], input) do
      request = %{
        "id" => definition["id"],
        "kind" => definition["kind"],
        "thing_id" => definition["thing_id"],
        "parameters" => parameters,
        "expected_generation" => socket.assigns.manage_generation
      }

      result =
        Auth.request(socket, :save_policy, %{
          "operation" => socket.assigns.manage_operation,
          "request" => request
        })

      {:noreply, manage_result(socket, result)}
    else
      false -> {:noreply, assign(socket, manage_error: %{"code" => "forbidden"})}
      :error -> {:noreply, assign(socket, manage_error: %{"code" => "invalid_request"})}
    end
  end

  def handle_event("delete", _, socket) do
    if manageable?(socket.assigns, "delete") do
      result =
        Auth.request(socket, :delete_policy, %{
          "operation" => socket.assigns.manage_operation,
          "request" => %{
            "id" => socket.assigns.definition["id"],
            "expected_generation" => socket.assigns.manage_generation
          }
        })

      {:noreply, manage_result(socket, result)}
    else
      {:noreply, assign(socket, manage_error: %{"code" => "forbidden"})}
    end
  end

  def handle_event("check-manage", _, socket), do: {:noreply, recover_manage(socket)}
  def handle_event(_, _, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <main id="main" class="workspace">
      <a href="/protection">← All tracking rules</a>
      <p class="eyebrow">{if @rule, do: Presenter.rule_kind(@rule["kind"]), else: "Tracking rule"}</p>
      <div class="heading">
        <h1>{if @rule, do: @rule["rule"]["id"], else: "Rule status unavailable"}</h1>
        <button class="secondary" phx-click="refresh">Refresh</button>
      </div>
      <.notice error={@error} />
      <section :if={@rule} class="panel" aria-labelledby="rule-status-title">
        <h2 id="rule-status-title">Current committed status</h2>
        <p class="reading">{Presenter.rule_status(@rule["status"])}</p>
        <p>
          The service evaluated this rule from retained evidence. The status does not prove current
          device connectivity, and this page does not arm or acknowledge the rule.
        </p>
        <.rule_details status={@rule} />
        <p class="identifier">Rule identity {@rule["rule"]["identity"]}</p>
        <p class="identifier">State identity {@rule["state_identity"]}</p>
      </section>
      <section :if={@rule} class="panel" aria-labelledby="rule-definition-title">
        <h2 id="rule-definition-title">Definition</h2>
        <div :if={@definition}>
          <p>
            Defined for <a href={Presenter.path(:asset, @definition["thing_id"])}>this asset</a>
            · revision {@definition["revision"]}. Saving a change evaluates it immediately.
          </p>
          <p :if={@definition["policy_identity"] != @rule["rule"]["identity"]} role="status">
            The displayed status was evaluated with a different revision of this definition.
          </p>
        </div>
        <p :if={is_nil(@definition)}>
          No active service definition. A host may manage this rule directly, or its definition was
          deleted; the retained status history stays readable and is no longer scheduled from a
          deleted definition.
        </p>
        <.notice error={@manage_error} />
        <div :if={@definition && @identity["can_manage_queries"] && is_nil(@manage_operation)}>
          <button
            :if={RuleForm.editable?(@definition["kind"], @definition["parameters"])}
            phx-click="prepare-manage"
            phx-value-intent="edit"
          >Prepare edit</button>
          <button class="secondary" phx-click="prepare-manage" phx-value-intent="delete">
            Prepare delete
          </button>
        </div>
        <p :if={
          @definition && @identity["can_manage_queries"] &&
            !RuleForm.editable?(@definition["kind"], @definition["parameters"])
        }>
          These parameters are not whole seconds or volts; edit them through the service API.
        </p>
        <.form
          :if={manageable?(assigns, "edit")}
          for={%{}}
          id="edit-rule"
          phx-submit="edit"
        >
          <RuleForm.fields
            heartbeat={@definition["kind"] == "heartbeat"}
            battery={@definition["kind"] == "battery"}
            parameters={@definition["parameters"]}
          />
          <button type="submit" phx-disable-with="Saving…">Save rule changes</button>
        </.form>
        <div :if={manageable?(assigns, "delete")}>
          <p>
            Deleting stops scheduled evaluation. The rule's retained status and history remain.
          </p>
          <button phx-click="delete" phx-disable-with="Deleting…">Delete rule definition</button>
        </div>
      </section>
      <section :if={@manage_operation} class="operation">
        <p :if={@manage_outcome} role="status">{manage_status(@manage_intent, @manage_outcome)}</p>
        <p :if={@manage_outcome && @manage_outcome["outcome"] != "committed"}>
          Keep this page's address and check the operation outcome before trying again.
        </p>
        <p class="identifier">Operation {@manage_operation}</p>
        <button class="secondary" phx-click="check-manage">Check operation outcome</button>
        <a href={Presenter.rule_path(@id)}>Start another change</a>
      </section>
      <section :if={@history} class="panel" aria-labelledby="rule-history-title">
        <h2 id="rule-history-title">Evaluation history</h2>
        <p>Committed status versions in commit order. Unchanged evaluations are not recorded.</p>
        <div class="table-scroll" tabindex="0" role="region" aria-labelledby="rule-history-title">
          <table>
            <caption>Retained rule status versions</caption>
            <thead>
              <tr>
                <th scope="col">Version</th><th scope="col">Status</th><th scope="col">
                  Rule revision
                </th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @history["items"]}>
                <td>{row["generation"]}</td>
                <td>{Presenter.rule_status(row["value"]["status"])}</td>
                <td>{row["value"]["rule"]["revision"]}</td>
              </tr>
            </tbody>
          </table>
        </div>
        <button :if={@history_back != []} class="secondary" phx-click="previous-history">
          Previous history page
        </button>
        <button :if={@history["cursor"]} class="secondary" phx-click="next-history">
          Next history page
        </button>
      </section>
    </main>
    """
  end

  defp load(socket) do
    case Auth.request(socket, :get, %{"resource" => "rules", "id" => socket.assigns.id}) do
      {:ok, %{"value" => rule}} ->
        socket
        |> assign(rule: rule, error: nil, history_back: [])
        |> definition()
        |> history(%{})

      {:error, %{"code" => code} = error} when code in ~w(forbidden unauthorized not_found) ->
        clear(socket, error)

      {:error, error} ->
        assign(socket, error: error)
    end
  end

  # Only a definition with the rule's own kind can describe it.
  defp definition(%{assigns: %{rule: %{"kind" => kind, "rule" => %{"id" => id}}}} = socket) do
    case Auth.request(socket, :get, %{"resource" => "policies", "id" => id}) do
      {:ok, %{"value" => %{"kind" => ^kind} = definition}} ->
        assign(socket, definition: definition)

      {:ok, _} ->
        assign(socket, definition: nil)

      {:error, %{"code" => "not_found"}} ->
        assign(socket, definition: nil)

      {:error, error} ->
        assign(socket, error: error)
    end
  end

  defp history(socket, params) do
    case Auth.request(socket, :history, %{
           "resource" => "rules",
           "id" => socket.assigns.id,
           "params" => params
         }) do
      {:ok, history} ->
        assign(socket, history: history, history_params: params, error: nil)

      {:error, %{"code" => code} = error} when code in ~w(forbidden unauthorized not_found) ->
        clear(socket, error)

      {:error, error} ->
        assign(socket, error: error)
    end
  end

  defp clear(socket, error),
    do:
      assign(socket,
        rule: nil,
        definition: nil,
        history: nil,
        history_params: nil,
        history_back: [],
        error: error
      )

  defp current_generation(socket) do
    case Auth.request(socket, :list, %{"resource" => "policies", "params" => %{"limit" => 1}}) do
      {:ok, %{"generation" => generation}} -> {:ok, generation}
      {:error, error} -> {:error, error}
    end
  end

  defp can_prepare?(assigns, intent) do
    definition = assigns.definition

    assigns.identity["can_manage_queries"] == true and is_map(definition) and
      is_nil(assigns.manage_operation) and
      (intent == "delete" or RuleForm.editable?(definition["kind"], definition["parameters"]))
  end

  defp manageable?(assigns, intent),
    do:
      assigns.identity["can_manage_queries"] == true and is_map(assigns.definition) and
        is_binary(assigns.manage_operation) and assigns.manage_intent == intent and
        is_binary(assigns.manage_generation) and is_nil(assigns.manage_outcome)

  defp activate_manage(socket, nil, nil),
    do:
      assign(socket,
        manage_operation: nil,
        manage_intent: nil,
        manage_generation: nil,
        manage_outcome: nil,
        manage_error: nil
      )

  defp activate_manage(socket, operation, intent)
       when is_binary(operation) and intent in ~w(edit delete) do
    cond do
      not Identifier.operation?(operation) ->
        assign(socket, manage_operation: nil, manage_error: %{"code" => "invalid_request"})

      socket.assigns.manage_operation == operation and socket.assigns.manage_intent == intent ->
        socket

      true ->
        prepared? =
          is_nil(socket.assigns.manage_operation) and is_binary(socket.assigns.manage_generation)

        assign(socket,
          manage_operation: operation,
          manage_intent: intent,
          manage_generation: if(prepared?, do: socket.assigns.manage_generation, else: nil),
          manage_outcome: nil,
          manage_error: nil
        )
    end
  end

  defp activate_manage(socket, _, _),
    do: assign(socket, manage_operation: nil, manage_error: %{"code" => "invalid_request"})

  defp recover_manage(%{assigns: %{manage_operation: nil}} = socket), do: socket

  defp recover_manage(socket) do
    case Auth.request(socket, :operation, %{"id" => socket.assigns.manage_operation}) do
      {:error, %{"code" => "not_found"}} -> socket
      result -> manage_result(socket, result)
    end
  end

  # A reconnect without a prepared generation reads the current one before showing a control.
  defp load_manage_generation(%{assigns: %{manage_operation: nil}} = socket), do: socket
  defp load_manage_generation(%{assigns: %{manage_outcome: %{}}} = socket), do: socket

  defp load_manage_generation(%{assigns: %{manage_generation: generation}} = socket)
       when is_binary(generation),
       do: socket

  defp load_manage_generation(%{assigns: %{definition: %{}}} = socket) do
    case current_generation(socket) do
      {:ok, generation} -> assign(socket, manage_generation: generation)
      {:error, error} -> assign(socket, manage_error: error)
    end
  end

  defp load_manage_generation(socket), do: socket

  defp manage_result(socket, {:ok, %{"outcome" => "committed", "data" => data} = receipt}) do
    [_kind, rule_id] = String.split(socket.assigns.id, ":", parts: 2)
    expected = if socket.assigns.manage_intent == "edit", do: "saved", else: "deleted"

    if data == %{"policy_id" => rule_id, "action" => expected},
      do: verify(socket, receipt, expected),
      else: unrelated_manage(socket)
  end

  defp manage_result(socket, {:ok, %{"outcome" => "unknown"} = receipt}),
    do: assign(socket, manage_outcome: receipt, manage_error: nil)

  defp manage_result(socket, {:ok, _}), do: unrelated_manage(socket)

  defp manage_result(socket, {:error, %{"outcome" => "not_committed"} = error}),
    do: assign(socket, manage_error: error)

  defp manage_result(socket, {:error, error}),
    do: assign(socket, manage_outcome: %{"outcome" => "unknown"}, manage_error: error)

  # Reload both projections; the receipt counts only when they reflect the action.
  defp verify(socket, receipt, expected) do
    reloaded = load(socket)

    cond do
      reloaded.assigns.error ->
        assign(reloaded,
          manage_outcome: %{"outcome" => "unknown"},
          manage_error: reloaded.assigns.error
        )

      expected == "saved" == is_map(reloaded.assigns.definition) ->
        assign(reloaded, manage_outcome: receipt, manage_error: nil)

      true ->
        unrelated_manage(reloaded)
    end
  end

  defp unrelated_manage(socket),
    do:
      assign(socket,
        manage_outcome: %{"outcome" => "unrelated"},
        manage_error: %{"code" => "operation_mismatch"}
      )

  defp manage_status("edit", %{"outcome" => "committed"}), do: "Rule definition updated"
  defp manage_status("delete", %{"outcome" => "committed"}), do: "Rule definition deleted"
  defp manage_status(_, _), do: "Operation outcome unknown"
end
