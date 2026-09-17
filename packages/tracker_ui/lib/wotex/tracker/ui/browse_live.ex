defmodule Wotex.Tracker.UI.BrowseLive do
  @moduledoc """
  Browses authorized assets and imports one observation capture.

  Asset cards load their latest committed state separately and distinguish
  retained readings from unknown connectivity. Asset and observation lists
  keep a bounded cursor back path and reload pages under current authority.
  Setup accepts one JSON capture file of at most 256 KiB, then submits it
  through the service with a stable operation reference for recovery.
  """

  use Phoenix.LiveView, log: false
  import Wotex.Tracker.UI.Components
  alias Wotex.Tracker.Service.{Codec, Identifier}
  alias Wotex.Tracker.UI.{Auth, Presenter}

  @page_back_limit 32

  @impl true
  def mount(_, _, socket) do
    {:ok,
     socket
     |> assign(
       page: nil,
       page_params: nil,
       page_back: [],
       summaries: %{},
       operational_enabled: socket.endpoint.config(:tracker_ui)[:operational_history] == true,
       operation: nil,
       outcome: nil,
       error: nil
     )
     |> allow_upload(:observation, accept: ~w(.json), max_entries: 1, max_file_size: 262_144)}
  end

  @impl true
  def handle_params(
        %{"operation" => operation},
        _,
        %{assigns: %{live_action: :observations}} = socket
      ) do
    if Identifier.operation?(operation) do
      {:noreply, socket |> activate_operation(operation) |> recover() |> first_page()}
    else
      {:noreply,
       assign(socket,
         operation: nil,
         outcome: nil,
         page: nil,
         page_params: nil,
         page_back: [],
         summaries: %{},
         error: %{"code" => "invalid_request"}
       )}
    end
  end

  def handle_params(_, _, %{assigns: %{live_action: :observations}} = socket),
    do: {:noreply, redirect(socket, to: "/setup?operation=" <> Identifier.uuid())}

  def handle_params(_, _, socket), do: {:noreply, first_page(socket)}

  @impl true
  def handle_event("refresh", _, socket), do: {:noreply, socket |> recover() |> first_page()}

  def handle_event("validate-import", _, socket), do: {:noreply, socket}

  def handle_event(
        "import",
        _,
        %{
          assigns: %{
            live_action: :observations,
            page: %{},
            operation: operation,
            outcome: nil,
            identity: %{"can_ingest" => true}
          }
        } = socket
      )
      when is_binary(operation) do
    case capture(socket) do
      {:ok, document} ->
        result =
          Auth.request(socket, :submit, %{
            "operation" => operation,
            "request" => %{
              "observation" => document,
              "expected_generation" => socket.assigns.page["generation"]
            }
          })

        {:noreply, socket |> outcome(result) |> first_page()}

      :error ->
        {:noreply, assign(socket, error: %{"code" => "invalid_request"})}
    end
  end

  def handle_event("import", _, socket),
    do: {:noreply, assign(socket, error: %{"code" => "forbidden"})}

  def handle_event("check-import", _, socket), do: {:noreply, socket |> recover() |> first_page()}

  def handle_event("next", _, %{assigns: %{page: %{"cursor" => cursor}}} = socket)
      when is_binary(cursor) do
    next = load(socket, %{"cursor" => cursor})

    if next.assigns.page_params == %{"cursor" => cursor} do
      back = [socket.assigns.page_params | socket.assigns.page_back]
      {:noreply, assign(next, page_back: Enum.take(back, @page_back_limit), error: nil)}
    else
      {:noreply, next}
    end
  end

  def handle_event("previous", _, %{assigns: %{page_back: [params | rest]}} = socket) do
    previous = load(socket, params)

    cond do
      previous.assigns.page_params != params ->
        {:noreply, previous}

      previous.assigns.page["generation"] != socket.assigns.page["generation"] ->
        {:noreply, assign(socket, error: %{"code" => "conflict"})}

      true ->
        {:noreply, assign(previous, page_back: rest, error: nil)}
    end
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <main id="main" class="workspace">
      <p class="eyebrow">Scope · {@identity["scope"]}</p>
      <div class="heading">
        <div>
          <h1>{if @live_action == :assets, do: "Your assets", else: "Set up a tracker"}</h1>
          <p :if={@live_action == :assets}>Inspect retained evidence and continue provisioning.</p>
          <p :if={@live_action == :observations}>
            Import a capture or choose an observation, inspect its evidence and confirm ownership.
          </p>
        </div>
        <button class="secondary" phx-click="refresh">Refresh</button>
      </div>
      <a :if={@operational_enabled && @identity["can_manage_queries"]} href="/operations">
        Operational history
      </a>
      <.notice error={@error} />
      <section
        :if={
          @live_action == :observations && @identity["can_ingest"] && @page && @operation &&
            is_nil(@outcome)
        }
        class="panel"
      >
        <h2>Import an observation capture</h2>
        <p>
          Choose one Observation JSON file, up to 256 KiB. The service checks its evidence before saving it.
        </p>
        <.form for={%{}} id="import-capture" phx-change="validate-import" phx-submit="import">
          <label for={@uploads.observation.ref}>Observation JSON capture</label>
          <.live_file_input upload={@uploads.observation} />
          <p :if={invalid_upload?(@uploads.observation)} class="notice" role="alert">
            Choose one JSON capture of 256 KiB or less.
          </p>
          <button type="submit" phx-disable-with="Importing…">Import capture</button>
        </.form>
      </section>
      <p :if={@live_action == :observations && !@identity["can_ingest"]} class="notice">
        This credential can inspect observations but cannot import captures.
      </p>
      <section :if={@live_action == :observations && @outcome} class="panel" role="status">
        <h2>
          {if @outcome["outcome"] == "committed",
            do: "Capture imported",
            else: "Import outcome unknown"}
        </h2>
        <a
          :if={@outcome["outcome"] == "committed" && @outcome["data"]["observation_id"]}
          class="button"
          href={Presenter.path(:observation, @outcome["data"]["observation_id"])}
        >Inspect observation</a>
        <p :if={@outcome["outcome"] != "committed"}>
          Keep this page's address. Check the outcome before starting another import.
        </p>
      </section>
      <div :if={@live_action == :observations && @operation} class="operation">
        <p>Operation reference <code>{@operation}</code></p>
        <button class="secondary" phx-click="check-import">Check operation outcome</button>
        <a :if={@outcome && @outcome["outcome"] == "committed"} href="/setup">
          Start another import
        </a>
      </div>
      <section :if={@page} aria-label="Records">
        <div :if={@page["items"] == []} class="empty">
          <h2>
            {if @live_action == :assets,
              do: "No assets on this page",
              else: "No observations on this page"}
          </h2>
          <p :if={@live_action == :assets}>Start with an observation to enroll your first asset.</p>
          <p :if={@live_action == :observations}>
            This service has no observation to show here. Connect an admitted source or import a capture above.
          </p>
          <a :if={@live_action == :assets} class="button" href="/setup">Open setup</a>
        </div>
        <p :if={@live_action == :assets && @page["items"] != []} class="muted">
          Each asset summary is a separate authorized read. Refresh to check the latest committed readings.
        </p>
        <div class="cards">
          <article :for={row <- @page["items"]} class="card">
            <p class="eyebrow">
              {if @live_action == :assets, do: "Enrolled asset", else: row["value"]["ingress"]}
            </p>
            <h2>
              <a href={
                Presenter.path(if(@live_action == :assets, do: :asset, else: :observation), row["id"])
              }>
                {if @live_action == :assets, do: row["value"]["title"], else: "Inspect observation"}
              </a>
            </h2>
            <p :if={@live_action == :observations}>
              {Presenter.timestamp(row["value"]["observed_at"])}
            </p>
            <p class="identifier">{row["id"]}</p>
            <p :if={@live_action == :assets} class="muted">
              Ownership confirmed · open for measurements and provisioning
            </p>
            <.asset_summary
              :if={@live_action == :assets}
              summary={Map.fetch!(@summaries, row["id"])}
              enrollment={row["value"]}
            />
          </article>
        </div>
        <button :if={@page_back != []} class="secondary" phx-click="previous">Previous page</button>
        <button :if={@page["cursor"]} class="secondary" phx-click="next">Next page</button>
      </section>
    </main>
    """
  end

  defp load(socket, params) do
    resource = if socket.assigns.live_action == :assets, do: "enrollments", else: "observations"

    case Auth.request(socket, :list, %{"resource" => resource, "params" => params}) do
      {:ok, page} ->
        case summaries(socket, page) do
          {:ok, summaries} ->
            assign(socket, page: page, page_params: params, summaries: summaries)

          {:error, error} ->
            assign(socket,
              page: nil,
              page_params: nil,
              page_back: [],
              summaries: %{},
              error: error
            )
        end

      {:error, %{"code" => code} = error} when code in ~w(forbidden unauthorized) ->
        assign(socket, page: nil, page_params: nil, page_back: [], summaries: %{}, error: error)

      {:error, error} ->
        assign(socket, error: error)
    end
  end

  defp first_page(socket) do
    first = load(socket, %{})
    if first.assigns.page_params == %{}, do: assign(first, page_back: []), else: first
  end

  defp summaries(%{assigns: %{live_action: :assets}} = socket, %{"items" => rows}) do
    Enum.reduce_while(rows, {:ok, %{}}, fn row, {:ok, summaries} ->
      summary =
        case Auth.request(socket, :get, %{"resource" => "state", "id" => row["id"]}) do
          {:ok, %{"value" => state}} ->
            rules(socket, row["id"], state)

          {:error, %{"code" => "not_found"}} ->
            %{status: :unprovisioned, state: nil}

          {:error, %{"code" => code} = error} when code in ~w(forbidden unauthorized) ->
            {:error, error}

          _ ->
            %{status: :unavailable, state: nil}
        end

      case summary do
        {:error, error} -> {:halt, {:error, error}}
        value -> {:cont, {:ok, Map.put(summaries, row["id"], value)}}
      end
    end)
  end

  defp summaries(_, _), do: {:ok, %{}}

  # Rule status is secondary to readings, so its failure does not hide them.
  defp rules(socket, id, state) do
    case Auth.request(socket, :thing_rules, %{"thing" => id}) do
      {:ok, %{"items" => items}} when is_list(items) ->
        %{status: :recorded, state: state, rules: items}

      {:error, %{"code" => code} = error} when code in ~w(forbidden unauthorized) ->
        {:error, error}

      _ ->
        %{status: :recorded, state: state, rules: :unavailable}
    end
  end

  attr(:summary, :map, required: true)
  attr(:enrollment, :map, required: true)

  defp asset_summary(assigns) do
    ~H"""
    <div class="asset-summary">
      <p :if={@summary.status == :unprovisioned}>
        No committed measurements yet. Provision this asset to inspect its readings.
      </p>
      <p :if={@summary.status == :unavailable} role="status">
        Measurement summary unavailable. Refresh or open the asset for details.
      </p>
      <div :if={@summary.status == :recorded}>
        <p>Last recorded {Presenter.timestamp(@summary.state["observed_at"])}.</p>
        <p :if={@summary.state["observation_id"] != @enrollment["observation_id"]}>
          These readings came from the prior associated observation. Update the Thing to publish the new source.
        </p>
        <ul class="summary-values">
          <li :for={measurement <- @summary.state["measurements"]}>
            {Presenter.label(measurement["kind"])}: {Presenter.scalar(measurement["value"])} {Presenter.unit(
              measurement["unit"]
            )} · {measurement["availability"]}, {measurement["quality"]}
          </li>
        </ul>
        <p class="muted">Retained readings; current device connectivity is unknown.</p>
        <p :if={@summary.rules == :unavailable} role="status">Rule status unavailable.</p>
        <p :if={@summary.rules == []} class="muted">No protection rules defined.</p>
        <ul :if={is_list(@summary.rules) && @summary.rules != []} class="summary-values rule-summary">
          <li :for={rule <- @summary.rules}>
            {Presenter.rule_kind(rule["value"]["kind"])}: {Presenter.rule_status(
              rule["value"]["status"]
            )}
            <strong :if={Presenter.rule_attention?(rule["value"]["status"])}> · needs attention</strong>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  defp capture(socket) do
    with {[entry], []} <- uploaded_entries(socket, :observation),
         true <- entry.done?,
         false <- invalid_upload?(socket.assigns.uploads.observation),
         [{:ok, document}] <-
           consume_uploaded_entries(socket, :observation, fn %{path: path}, _ ->
             {:ok, decode_capture(path)}
           end) do
      {:ok, document}
    else
      _ -> :error
    end
  end

  defp decode_capture(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, document} when is_map(document) <- Codec.decode(bytes) do
      {:ok, document}
    else
      _ -> :error
    end
  end

  defp invalid_upload?(upload) do
    upload_errors(upload) != [] or
      Enum.any?(upload.entries, &(upload_errors(upload, &1) != []))
  end

  defp activate_operation(socket, operation) do
    if socket.assigns.operation == operation,
      do: socket,
      else:
        assign(socket,
          operation: operation,
          outcome: nil,
          page: nil,
          page_params: nil,
          page_back: [],
          error: nil
        )
  end

  defp recover(%{assigns: %{operation: nil}} = socket), do: assign(socket, error: nil)

  defp recover(socket) do
    case Auth.request(socket, :operation, %{"id" => socket.assigns.operation}) do
      {:error, %{"code" => "not_found"}} ->
        if is_nil(socket.assigns.outcome), do: assign(socket, error: nil), else: socket

      result ->
        outcome(socket, result)
    end
  end

  defp outcome(
         socket,
         {:ok, %{"outcome" => "committed", "data" => %{"observation_id" => id} = data} = result}
       )
       when map_size(data) == 1 do
    generation = result["generation"]

    case Auth.request(socket, :get, %{"resource" => "observations", "id" => id}) do
      {:ok, %{"generation" => ^generation, "value" => %{"id" => ^id}}} ->
        assign(socket, outcome: result, error: nil)

      {:error, error} ->
        assign(socket, outcome: %{"outcome" => "unknown"}, error: error)

      _ ->
        unrelated(socket)
    end
  end

  defp outcome(socket, {:ok, %{"outcome" => "unknown"} = result}),
    do: assign(socket, outcome: result, error: nil)

  defp outcome(socket, {:ok, _}), do: unrelated(socket)

  defp outcome(socket, {:error, %{"outcome" => "not_committed"} = error}),
    do: assign(socket, error: error)

  defp outcome(socket, {:error, error}),
    do: assign(socket, outcome: %{"outcome" => "unknown"}, error: error)

  defp unrelated(socket),
    do:
      assign(socket,
        outcome: %{"outcome" => "unrelated"},
        error: %{"code" => "operation_mismatch"}
      )
end
