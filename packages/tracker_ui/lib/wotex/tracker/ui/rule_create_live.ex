defmodule Wotex.Tracker.UI.RuleCreateLive do
  @moduledoc """
  Lets an administrator add a heartbeat or battery rule to one provisioned asset.

  Preparing a rule captures the current scope generation and puts a fresh
  operation reference in the page address. The rule ID is derived from that
  reference, so a lost reply can be verified without submitting again. The
  service validates, stores and evaluates the definition; this page sends no
  notification and requests no physical Action.
  """

  use Phoenix.LiveView, log: false
  import Wotex.Tracker.UI.Components
  alias Wotex.Tracker.Service.Identifier
  alias Wotex.Tracker.UI.{Auth, Presenter}

  @maximum_seconds 604_800

  @impl true
  def mount(_, _, socket),
    do:
      {:ok,
       assign(socket,
         id: nil,
         asset: nil,
         thing: nil,
         operation: nil,
         generation: nil,
         outcome: nil,
         saved: nil,
         error: nil,
         maximum_seconds: @maximum_seconds
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
        %{assigns: %{operation: nil, thing: %{}, identity: %{"can_manage_queries" => true}}} =
          socket
      ) do
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
  def handle_event(_, _, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <main id="main" class="workspace narrow">
      <a href={Presenter.path(:asset, @id)}>← Asset details</a>
      <p class="eyebrow">Protection</p>
      <h1>{if @asset, do: "Add a rule for #{@asset["title"]}", else: "Asset unavailable"}</h1>
      <p>
        The service evaluates a rule from this asset's committed evidence when it is saved and
        whenever the asset is provisioned again. Alerts are recorded, not sent, and no physical
        Action is requested.
      </p>
      <.notice error={@error} />
      <p :if={@asset && !@identity["can_manage_queries"]}>
        Your credential can inspect rule status but cannot add rules.
      </p>
      <p :if={@asset && is_nil(@thing)}>
        Provision this asset before adding a rule; rules need its committed evidence.
      </p>
      <button
        :if={@thing && @identity["can_manage_queries"] && is_nil(@operation)}
        phx-click="prepare"
      >Prepare rule</button>
      <.form
        :if={
          @thing && @identity["can_manage_queries"] && @operation && @generation && is_nil(@outcome)
        }
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
          <label :if={battery?(@thing)}>
            <input type="radio" name="rule[kind]" value="battery" />
            Low battery voltage, with separate low and recovery thresholds
          </label>
        </fieldset>
        <fieldset>
          <legend>Reporting heartbeat</legend>
          <label for="rule-silence">Maximum silence (seconds)</label>
          <input
            id="rule-silence"
            name="rule[maximum_silence_seconds]"
            type="number"
            min="0"
            max={@maximum_seconds}
            value="3600"
          />
        </fieldset>
        <fieldset :if={battery?(@thing)}>
          <legend>Low battery voltage</legend>
          <label for="rule-low">Low at or below (V)</label>
          <input id="rule-low" name="rule[low_threshold]" type="text" inputmode="decimal" value="2.5" />
          <label for="rule-clear">Recovered at or above (V)</label>
          <input
            id="rule-clear"
            name="rule[clear_threshold]"
            type="text"
            inputmode="decimal"
            value="2.8"
          />
          <label for="rule-age">Maximum reading age (seconds)</label>
          <input
            id="rule-age"
            name="rule[maximum_age_seconds]"
            type="number"
            min="0"
            max={@maximum_seconds}
            value="86400"
          />
          <label class="checkbox">
            <input type="checkbox" name="rule[accept_suspect]" value="true" />
            Accept readings marked suspect
          </label>
        </fieldset>
        <label for="rule-skew">Permitted receiver clock skew (seconds)</label>
        <input
          id="rule-skew"
          name="rule[future_skew_seconds]"
          type="number"
          min="0"
          max={@maximum_seconds}
          value="60"
        />
        <button type="submit" phx-disable-with="Saving…">Save rule</button>
      </.form>
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
      assign(socket, asset: asset, thing: thing)
    else
      {:error, error} -> assign(socket, asset: nil, thing: nil, error: error)
    end
  end

  defp thing(socket) do
    case Auth.request(socket, :get, %{"resource" => "things", "id" => socket.assigns.id}) do
      {:ok, %{"value" => thing}} -> {:ok, thing}
      {:error, %{"code" => "not_found"}} -> {:ok, nil}
      error -> error
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
        assign(socket, outcome: receipt, saved: saved, error: nil)

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
    with {:ok, skew} <- seconds(input["future_skew_seconds"]),
         {:ok, parameters} <- parameters(input["kind"], input, skew, socket.assigns.thing) do
      {:ok,
       %{
         "id" => rule_id(socket.assigns.operation),
         "kind" => input["kind"],
         "thing_id" => socket.assigns.id,
         "parameters" => parameters,
         "expected_generation" => socket.assigns.generation
       }}
    end
  end

  defp parameters("heartbeat", input, skew, _thing) do
    with {:ok, silence} <- seconds(input["maximum_silence_seconds"]),
         do: {:ok, %{"maximum_silence_ms" => silence, "future_skew_ms" => skew}}
  end

  defp parameters("battery", input, skew, thing) do
    with true <- battery?(thing),
         {:ok, low} <- volts(input["low_threshold"]),
         {:ok, clear} <- volts(input["clear_threshold"]),
         true <- low < clear,
         {:ok, age} <- seconds(input["maximum_age_seconds"]),
         true <- input["accept_suspect"] in [nil, "true"] do
      {:ok,
       %{
         "measurement_kind" => "batteryVoltage",
         "unit" => "V",
         "low_threshold" => low,
         "clear_threshold" => clear,
         "maximum_age_ms" => age,
         "future_skew_ms" => skew,
         "accept_suspect" => input["accept_suspect"] == "true"
       }}
    else
      _ -> :error
    end
  end

  defp parameters(_, _, _, _), do: :error

  defp seconds(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds in 0..@maximum_seconds -> {:ok, seconds * 1_000}
      _ -> :error
    end
  end

  defp seconds(_), do: :error

  defp volts(value) when is_binary(value) do
    case Float.parse(value) do
      {volts, ""} when volts > 0 and volts < 100 -> {:ok, volts}
      _ -> :error
    end
  end

  defp volts(_), do: :error

  defp battery?(thing),
    do:
      match?(
        %{"type" => "number", "unit" => "V"},
        get_in(thing, ["properties", "batteryVoltage"])
      )

  defp rule_id(operation), do: "rule-" <> operation
end
