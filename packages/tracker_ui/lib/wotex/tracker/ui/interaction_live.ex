defmodule Wotex.Tracker.UI.InteractionLive do
  @moduledoc """
  Invokes one qualified Thing Action through the durable service boundary.

  The page retains an operation identity before invocation, requires a second
  explicit confirmation, sends at most one mutation request and recovers only
  through the read-only Action status resource. Protocol acceptance is never
  presented as device completion or a physical effect.
  """

  use Phoenix.LiveView, log: false
  import Wotex.Tracker.UI.Components
  alias Wotex.Tracker.Service.Identifier
  alias Wotex.Tracker.UI.{ActionForm, Auth, Presenter}

  @impl true
  def mount(_, _, socket) do
    {:ok,
     assign(socket,
       id: nil,
       asset: nil,
       generation: nil,
       actions: nil,
       operation: nil,
       selected: nil,
       prepared?: false,
       prepared_input: nil,
       admission: nil,
       status: nil,
       error: nil
     )}
  end

  @impl true
  def handle_params(%{"id" => id} = params, _, socket) do
    socket = if socket.assigns.id == id, do: socket, else: reset(socket, id)

    {:noreply,
     socket
     |> load()
     |> activate(params["operation"], params["action"])
     |> recover()}
  end

  @impl true
  def handle_event("refresh", _, socket), do: {:noreply, socket |> load() |> recover()}

  def handle_event(
        "prepare",
        %{"interaction" => %{"action" => name} = parameters},
        %{assigns: %{operation: nil, identity: %{"can_interact" => true}}} = socket
      )
      when is_binary(name) do
    with %{"supported" => true} = action <- action(socket.assigns.actions, name),
         true <- valid_parameters?(parameters, action["input"]),
         {:ok, input} <- ActionForm.decode_input(action["input"], parameters["value"]) do
      operation = Identifier.uuid()
      query = URI.encode_query(%{"operation" => operation, "action" => name})

      {:noreply,
       socket
       |> assign(
         operation: operation,
         selected: action,
         prepared?: true,
         prepared_input: input,
         admission: nil,
         status: nil,
         error: nil
       )
       |> push_patch(to: Presenter.interaction_path(socket.assigns.id) <> "?" <> query)}
    else
      _ -> {:noreply, assign(socket, error: %{"code" => "invalid_request"})}
    end
  end

  def handle_event("prepare", _, socket),
    do: {:noreply, assign(socket, error: %{"code" => "forbidden"})}

  def handle_event(
        "invoke",
        %{"interaction" => %{"confirmed" => "yes"}},
        %{
          assigns: %{
            identity: %{"can_interact" => true},
            operation: operation,
            selected: %{"name" => name},
            prepared?: true,
            generation: generation,
            admission: nil,
            status: nil
          }
        } = socket
      )
      when is_binary(operation) and is_binary(generation) do
    result =
      Auth.request(socket, :invoke_action, %{
        "operation" => operation,
        "thing" => socket.assigns.id,
        "name" => name,
        "request" => %{
          "expected_generation" => generation,
          "input" => socket.assigns.prepared_input
        }
      })

    {:noreply, invocation_result(socket, result)}
  end

  def handle_event("invoke", _, socket),
    do: {:noreply, assign(socket, error: %{"code" => "invalid_request"})}

  def handle_event("check-action", _, socket), do: {:noreply, recover(socket)}
  def handle_event(_, _, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <main id="main" class="workspace narrow">
      <a href={Presenter.path(:asset, @id)}>← Asset details</a>
      <p class="eyebrow">Interactions</p>
      <div class="heading">
        <h1>{if @asset, do: "Actions for #{@asset["title"]}", else: "Actions unavailable"}</h1>
        <button class="secondary" phx-click="refresh">Refresh</button>
      </div>
      <p>
        An invocation is admitted once and may cause a physical device change. The service never
        retries an ambiguous dispatch. Queued or protocol-accepted work is not proof that the device
        received, completed or physically applied an Action.
      </p>
      <.notice error={@error} />

      <section :if={@asset && @actions == []} class="panel">
        <h2>No declared Actions</h2>
        <p>
          This Thing exposes no qualified Action. Property reads and retained measurements remain
          available from the asset page.
        </p>
      </section>

      <section :if={@asset && @actions != [] && is_nil(@operation)} class="panel">
        <h2>Declared Actions</h2>
        <p :if={!@identity["can_interact"]}>
          Your credential can inspect these declarations but cannot invoke them.
        </p>
        <article :for={{action, index} <- Enum.with_index(@actions)} class="card">
          <h3>{action["title"]}</h3>
          <p :if={action["description"]}>{action["description"]}</p>
          <p :if={!action["supported"]} class="notice">
            This Action's input constraints are not supported by the shared interaction form.
          </p>
          <.form
            :if={action["supported"] && @identity["can_interact"]}
            for={%{}}
            id={"prepare-action-#{index}"}
            phx-submit="prepare"
          >
            <input type="hidden" name="interaction[action]" value={action["name"]} />
            <label :if={action["input"]} for={"action-input-#{index}"}>
              Input {input_unit(action["input"])}
            </label>
            <select
              :if={input_type(action) == "boolean"}
              id={"action-input-#{index}"}
              name="interaction[value]"
            >
              <option value="true">True</option>
              <option value="false">False</option>
            </select>
            <input
              :if={input_type(action) in ~w(integer number)}
              id={"action-input-#{index}"}
              name="interaction[value]"
              type="number"
              step={if input_type(action) == "integer", do: "1", else: "any"}
              min={action["input"]["minimum"]}
              max={action["input"]["maximum"]}
            />
            <input
              :if={input_type(action) == "string"}
              id={"action-input-#{index}"}
              name="interaction[value]"
              type="text"
              minlength={action["input"]["minLength"]}
              maxlength={action["input"]["maxLength"]}
            />
            <button type="submit">Prepare {action["title"]}</button>
          </.form>
        </article>
      </section>

      <section :if={@operation && @prepared? && @selected} class="panel">
        <h2>Confirm {@selected["title"]}</h2>
        <p>
          Review the exact input: <code>{input_summary(@prepared_input)}</code>. Invoking sends one
          request. A timeout or disconnect will not cause an automatic retry.
        </p>
        <.form for={%{}} id="action-confirmation" phx-submit="invoke">
          <label>
            <input type="checkbox" name="interaction[confirmed]" value="yes" required />
            I authorize this Action and understand that acceptance is not physical completion.
          </label>
          <button type="submit" phx-disable-with="Invoking once…">Invoke once</button>
        </.form>
      </section>

      <section :if={@operation} class="operation" aria-labelledby="action-outcome-title">
        <h2 id="action-outcome-title">Action outcome</h2>
        <p :if={@admission == "unknown"} role="status">
          Invocation admission outcome unknown. Do not submit the Action again; check this operation.
        </p>
        <p :if={@admission == "not_committed"} role="status">
          Invocation was not committed. Review the error before preparing a new operation.
        </p>
        <p :if={@status} role="status">{status_label(@status)}</p>
        <dl :if={@status}>
          <dt>Action</dt><dd>{@status["action"]}</dd>
          <dt>Thing generation</dt><dd>{@status["thing"]["generation"]}</dd>
          <dt>Admitted</dt><dd>{Presenter.timestamp(%{"value" => @status["admitted_at"]})}</dd>
          <dt>Dispatch status</dt><dd>{@status["status"]}</dd>
          <dt>Physical effect</dt><dd>{physical_effect(@status)}</dd>
          <dt :if={@status["outcome"]}>Classification</dt>
          <dd :if={@status["outcome"]}>{@status["outcome"]["classification"]}</dd>
        </dl>
        <p :if={!@prepared? && is_nil(@admission) && is_nil(@status)} role="status">
          No retained outcome was found. This page did not resubmit the Action.
        </p>
        <p class="identifier">Operation {@operation}</p>
        <button class="secondary" phx-click="check-action">Check Action outcome</button>
        <a href={Presenter.interaction_path(@id)}>Prepare a different Action</a>
      </section>
    </main>
    """
  end

  defp load(socket) do
    with {:ok, %{"value" => asset}} <-
           Auth.request(socket, :get, %{"resource" => "enrollments", "id" => socket.assigns.id}),
         {:ok, %{"value" => thing, "generation" => generation}} <-
           Auth.request(socket, :get, %{"resource" => "things", "id" => socket.assigns.id}),
         true <- generation?(generation),
         {:ok, actions} <- ActionForm.actions(thing) do
      assign(socket, asset: asset, generation: generation, actions: actions, error: nil)
    else
      {:error, %{"code" => code} = error} when code in ~w(forbidden unauthorized not_found) ->
        clear(socket, error)

      {:error, error} ->
        assign(socket, error: error)

      _ ->
        assign(socket,
          asset: nil,
          generation: nil,
          actions: nil,
          error: %{"code" => "unavailable"}
        )
    end
  end

  defp activate(socket, nil, nil),
    do:
      assign(socket,
        operation: nil,
        selected: nil,
        prepared?: false,
        prepared_input: nil,
        admission: nil,
        status: nil
      )

  defp activate(socket, operation, name) when is_binary(operation) and is_binary(name) do
    cond do
      not Identifier.operation?(operation) or not action_name?(name) ->
        clear_operation(socket, %{"code" => "invalid_request"})

      socket.assigns.operation == operation and selected_name(socket) == name ->
        socket

      true ->
        assign(socket,
          operation: operation,
          selected: action(socket.assigns.actions, name) || %{"name" => name, "title" => name},
          prepared?: false,
          prepared_input: nil,
          admission: nil,
          status: nil
        )
    end
  end

  defp activate(socket, _, _), do: clear_operation(socket, %{"code" => "invalid_request"})

  defp invocation_result(
         socket,
         {:ok,
          %{
            "outcome" => "committed",
            "operation_id" => operation,
            "disposition" => "queued",
            "data" => %{"action_id" => operation, "status" => "queued"}
          }}
       )
       when operation == socket.assigns.operation do
    socket
    |> assign(prepared?: false, prepared_input: nil, admission: "queued", error: nil)
    |> recover()
  end

  defp invocation_result(
         socket,
         {:ok, %{"outcome" => "unknown", "operation_id" => operation}}
       )
       when operation == socket.assigns.operation,
       do:
         assign(socket,
           prepared?: false,
           prepared_input: nil,
           admission: "unknown",
           status: nil,
           error: nil
         )

  defp invocation_result(socket, {:error, %{"outcome" => "not_committed"} = error}),
    do:
      assign(socket,
        prepared?: false,
        prepared_input: nil,
        admission: "not_committed",
        status: nil,
        error: error
      )

  defp invocation_result(socket, {:error, error}),
    do:
      assign(socket,
        prepared?: false,
        prepared_input: nil,
        admission: "unknown",
        status: nil,
        error: error
      )

  defp invocation_result(socket, _),
    do:
      assign(socket,
        prepared?: false,
        prepared_input: nil,
        admission: "unknown",
        status: nil,
        error: %{"code" => "operation_mismatch"}
      )

  defp recover(%{assigns: %{operation: nil}} = socket), do: socket

  defp recover(socket) do
    case Auth.request(socket, :action_status, %{"operation" => socket.assigns.operation}) do
      {:ok, status} ->
        if ActionForm.status?(
             status,
             socket.assigns.operation,
             socket.assigns.id,
             selected_name(socket)
           ) do
          assign(socket,
            prepared?: false,
            prepared_input: nil,
            admission: "queued",
            status: status,
            error: nil
          )
        else
          assign(socket, status: nil, error: %{"code" => "operation_mismatch"})
        end

      {:error, %{"code" => "not_found"}} ->
        socket

      {:error, error} ->
        assign(socket, error: error)
    end
  end

  defp reset(socket, id),
    do:
      assign(socket,
        id: id,
        asset: nil,
        generation: nil,
        actions: nil,
        operation: nil,
        selected: nil,
        prepared?: false,
        prepared_input: nil,
        admission: nil,
        status: nil,
        error: nil
      )

  defp clear(socket, error),
    do:
      assign(socket,
        asset: nil,
        generation: nil,
        actions: nil,
        operation: nil,
        selected: nil,
        prepared?: false,
        prepared_input: nil,
        admission: nil,
        status: nil,
        error: error
      )

  defp clear_operation(socket, error),
    do:
      assign(socket,
        operation: nil,
        selected: nil,
        prepared?: false,
        prepared_input: nil,
        admission: nil,
        status: nil,
        error: error
      )

  defp action(actions, name) when is_list(actions), do: Enum.find(actions, &(&1["name"] == name))
  defp action(_, _), do: nil
  defp selected_name(socket), do: socket.assigns.selected["name"]
  defp input_type(%{"input" => %{"type" => type}}), do: type
  defp input_type(_), do: nil

  defp input_unit(%{"unit" => unit}) when is_binary(unit) do
    case Presenter.unit(unit) do
      "" -> ""
      rendered -> "(" <> rendered <> ")"
    end
  end

  defp input_unit(_), do: ""
  defp input_summary(nil), do: "No input"
  defp input_summary(value), do: Jason.encode!(value)

  defp valid_parameters?(parameters, nil), do: Map.keys(parameters) == ["action"]

  defp valid_parameters?(parameters, _),
    do: Enum.sort(Map.keys(parameters)) == ~w(action value)

  defp generation?(generation) when is_binary(generation) do
    case Integer.parse(generation) do
      {value, ""} when value >= 0 -> Integer.to_string(value) == generation
      _ -> false
    end
  end

  defp generation?(_), do: false

  defp action_name?(value),
    do:
      byte_size(value) in 1..128 and String.valid?(value) and
        not String.contains?(value, ["\0", "\r", "\n"])

  defp status_label(%{"status" => "queued"}), do: "Action queued for one dispatch attempt"
  defp status_label(%{"status" => "unknown"}), do: "Action dispatch outcome unknown"
  defp status_label(%{"status" => "accepted"}), do: "Action protocol accepted"
  defp status_label(%{"status" => "denied"}), do: "Action denied before dispatch"
  defp status_label(%{"status" => "failed"}), do: "Action failed before transport"

  defp physical_effect(%{"physical_effect" => "not_dispatched"}), do: "Not dispatched"
  defp physical_effect(_), do: "Unknown — device completion is not proven"
end
