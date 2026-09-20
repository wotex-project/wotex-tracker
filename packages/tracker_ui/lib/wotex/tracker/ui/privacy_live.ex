defmodule Wotex.Tracker.UI.PrivacyLive do
  @moduledoc """
  Presents retained scope data and a recoverable administrator deletion workflow.

  The page admits exact service projections before showing any counts. Preparing
  deletion refreshes the projection and captures its generation under a stable
  operation reference. Submission requires the service's literal confirmation
  phrase. A committed receipt is reported as success only after a fresh privacy
  projection contains the matching deletion marker and the expected minimal
  post-deletion rows.
  """

  use Phoenix.LiveView, log: false
  import Wotex.Tracker.UI.Components
  alias Wotex.Tracker.Service.{Codec, Identifier}
  alias Wotex.Tracker.UI.{Auth, Presenter}

  @confirmation "delete retained domain data"
  @retained_keys ~w(
    observations
    record_versions
    events
    publications
    queued_deliveries
    action_intents
    rule_states
    rule_event_intents
    operation_receipts
  )
  @preserved_keys ~w(credential_revocations successful_access_entries)
  @post_deletion %{
    "observations" => 0,
    "record_versions" => 1,
    "events" => 1,
    "publications" => 0,
    "queued_deliveries" => 0,
    "action_intents" => 0,
    "rule_states" => 0,
    "rule_event_intents" => 0,
    "operation_receipts" => 1
  }
  @base_policy %{
    "deletion_scope" => "all_retained_domain_data_in_scope",
    "credential_revocations" => "preserved_for_access_control",
    "successful_access_audit" => %{
      "retention_ms" => 2_592_000_000,
      "maximum_entries" => 10_000
    },
    "backups" => "outside_managed_primary_store",
    "offline_exports" => "outside_managed_primary_store",
    "remote_publications" => "outside_managed_primary_store"
  }

  @impl true
  def mount(_, _, socket) do
    {:ok,
     assign(socket,
       privacy: nil,
       operation: nil,
       generation: nil,
       outcome: nil,
       deleted: nil,
       closed: false,
       error: nil
     )}
  end

  @impl true
  def handle_params(params, _, socket) do
    {:noreply, socket |> load() |> activate(params["operation"]) |> recover()}
  end

  @impl true
  def handle_event(
        "prepare",
        _,
        %{assigns: %{operation: nil, identity: %{"can_manage_queries" => true}}} = socket
      ) do
    case refresh(socket) do
      {:ok, socket} ->
        {:noreply,
         socket
         |> assign(generation: socket.assigns.privacy["generation"], error: nil)
         |> push_patch(to: "/privacy?operation=" <> Identifier.uuid())}

      {:error, socket} ->
        {:noreply, socket}
    end
  end

  def handle_event("prepare", _, socket),
    do: {:noreply, assign(socket, error: %{"code" => "forbidden"})}

  def handle_event(
        "delete",
        %{"deletion" => %{"confirmation" => @confirmation}},
        %{
          assigns: %{
            privacy: %{},
            operation: operation,
            generation: generation,
            outcome: nil,
            closed: false,
            identity: %{"can_manage_queries" => true}
          }
        } = socket
      )
      when is_binary(operation) and is_binary(generation) do
    request = %{"expected_generation" => generation, "confirmation" => @confirmation}

    result =
      Auth.request(socket, :delete_domain_data, %{
        "operation" => operation,
        "request" => request
      })

    {:noreply, result(socket, result)}
  end

  def handle_event("delete", %{"deletion" => %{"confirmation" => @confirmation}}, socket),
    do:
      {:noreply,
       if(socket.assigns.outcome,
         do: socket,
         else: assign(socket, error: %{"code" => "forbidden"})
       )}

  def handle_event("delete", _, socket),
    do: {:noreply, assign(socket, error: %{"code" => "invalid_request"})}

  def handle_event("check-operation", _, socket), do: {:noreply, recover(socket)}
  def handle_event(_, _, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:confirmation, @confirmation)
      |> assign(:retained_rows, retained_rows(assigns.privacy))
      |> assign(:preserved_rows, preserved_rows(assigns.privacy))

    ~H"""
    <main id="main" class="workspace narrow">
      <p class="eyebrow">Privacy</p>
      <h1>Retained scope data</h1>
      <.notice error={@error} />

      <section
        :if={!@identity["can_manage_queries"]}
        class="panel"
        aria-labelledby="privacy-access-title"
      >
        <h2 id="privacy-access-title">Administrator access required</h2>
        <p>
          Your credential can use Tracker but cannot inspect or delete retained data for this scope.
        </p>
      </section>

      <section
        :if={@identity["can_manage_queries"] && is_nil(@privacy)}
        class="panel"
        aria-labelledby="privacy-unavailable-title"
      >
        <h2 id="privacy-unavailable-title">Retention details unavailable</h2>
        <p>No deletion can be prepared until the service returns a valid current projection.</p>
      </section>

      <div :if={@identity["can_manage_queries"] && @privacy}>
        <section class="panel" aria-labelledby="retained-data-title">
          <h2 id="retained-data-title">Managed primary-store data</h2>
          <p>
            These exact counts describe the current scope at generation <span class="identifier">{@privacy["generation"]}</span>. {retention_description(
              @privacy["policy"]
            )}
          </p>
          <div class="table-scroll">
            <table>
              <caption>Retained rows in the managed primary store</caption>
              <thead>
                <tr>
                  <th scope="col">Category</th><th scope="col">Rows</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={{label, count} <- @retained_rows}>
                  <th scope="row">{label}</th><td>{count}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <section class="panel" aria-labelledby="preserved-data-title">
          <h2 id="preserved-data-title">Security records preserved</h2>
          <p>
            Deletion preserves access-control revocations and the separately bounded successful-access
            audit, so erased data does not reactivate a credential or erase its security journal.
          </p>
          <div class="table-scroll">
            <table>
              <caption>Rows preserved by domain-data deletion</caption>
              <thead>
                <tr>
                  <th scope="col">Category</th><th scope="col">Rows</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={{label, count} <- @preserved_rows}>
                  <th scope="row">{label}</th><td>{count}</td>
                </tr>
              </tbody>
            </table>
          </div>
          <p class="muted">
            Successful access entries are retained for 30 days, up to 10,000 entries per scope.
          </p>
        </section>

        <section :if={@privacy["last_deletion"]} class="panel" aria-labelledby="last-deletion-title">
          <h2 id="last-deletion-title">Last verified deletion</h2>
          <p>
            Deleted {Presenter.timestamp(%{"value" => @privacy["last_deletion"]["deleted_at"]})} at generation <span class="identifier">{@privacy["last_deletion"]["generation"]}</span>.
            Cause: {deletion_cause(@privacy["last_deletion"])}.
          </p>
        </section>

        <section class="panel" aria-labelledby="delete-domain-data-title">
          <h2 id="delete-domain-data-title">Delete all retained domain data</h2>
          <p>
            This irreversible operation deletes every managed domain category shown above, including:
          </p>
          <ul>
            <li>assets, current state, observations, evidence and retained history;</li>
            <li>alerts, protection rules and their current evaluation state;</li>
            <li>saved dashboards, notification installations and queued deliveries; and</li>
            <li>prior domain operation receipts and the current event stream.</li>
          </ul>
          <p>
            Consistent backups, offline exports and data already sent to remote destinations are outside
            the managed primary store and are <strong>not deleted</strong>. Remove those copies separately.
          </p>
          <p>This operation has no per-asset selection and cannot be undone.</p>

          <button :if={is_nil(@operation)} class="secondary" phx-click="prepare">
            Prepare data deletion
          </button>

          <.form
            :if={@operation && @generation && is_nil(@outcome) && !@closed}
            for={%{}}
            id="delete-domain-data"
            phx-submit="delete"
          >
            <p id="deletion-confirmation-help">
              Type <code>{@confirmation}</code>
              exactly to confirm deletion at generation {@generation}.
            </p>
            <label for="deletion-confirmation">Confirmation phrase</label>
            <input
              id="deletion-confirmation"
              name="deletion[confirmation]"
              type="text"
              autocomplete="off"
              aria-describedby="deletion-confirmation-help"
            />
            <button type="submit" phx-disable-with="Deleting…">Delete retained domain data</button>
            <a href="/privacy">Cancel deletion</a>
          </.form>
        </section>
      </div>

      <section :if={@operation} class="operation" aria-labelledby="deletion-operation-title">
        <h2 id="deletion-operation-title">Deletion operation</h2>
        <p :if={@deleted} role="status">Retained domain data deleted and verified</p>
        <p :if={@outcome && !@deleted} role="status">Deletion outcome unknown</p>
        <p :if={@outcome && !@deleted}>
          Keep this page's address and check the operation outcome before starting another deletion.
        </p>
        <p class="identifier">Operation {@operation}</p>
        <button class="secondary" phx-click="check-operation">Check operation outcome</button>
      </section>
    </main>
    """
  end

  defp load(%{assigns: %{identity: %{"can_manage_queries" => true}}} = socket) do
    case refresh(socket) do
      {:ok, socket} -> socket
      {:error, socket} -> socket
    end
  end

  defp load(socket), do: assign(socket, privacy: nil, error: nil)

  defp refresh(socket) do
    case Auth.request(socket, :privacy) do
      {:ok, privacy} ->
        if privacy?(privacy),
          do: {:ok, assign(socket, privacy: privacy, error: nil)},
          else: {:error, assign(socket, error: %{"code" => "storage_unavailable"})}

      {:error, error} ->
        {:error, assign(socket, error: error)}
    end
  end

  defp activate(socket, nil),
    do: assign(socket, operation: nil, generation: nil, outcome: nil, deleted: nil, closed: false)

  defp activate(%{assigns: %{identity: %{"can_manage_queries" => false}}} = socket, _),
    do: assign(socket, operation: nil, error: %{"code" => "forbidden"})

  defp activate(socket, operation) do
    cond do
      not Identifier.operation?(operation) ->
        assign(socket, operation: nil, error: %{"code" => "invalid_request"})

      socket.assigns.operation == operation ->
        socket

      is_nil(socket.assigns.privacy) ->
        assign(socket, operation: nil)

      true ->
        assign(socket,
          operation: operation,
          generation: socket.assigns.privacy["generation"],
          outcome: nil,
          deleted: nil,
          closed: false
        )
    end
  end

  defp recover(%{assigns: %{operation: nil}} = socket), do: socket

  defp recover(socket) do
    case Auth.request(socket, :operation, %{"id" => socket.assigns.operation}) do
      {:error, %{"code" => "not_found"}} -> socket
      result -> result(socket, result)
    end
  end

  defp result(socket, {:ok, receipt}) do
    cond do
      committed_receipt?(receipt, socket.assigns.operation) ->
        verify(socket, receipt)

      unknown_receipt?(receipt, socket.assigns.operation) ->
        assign(socket, outcome: receipt, error: nil)

      true ->
        unrelated(socket)
    end
  end

  defp result(socket, {:error, %{"outcome" => "not_committed"} = error}),
    do: assign(socket, error: error, closed: true)

  defp result(socket, {:error, error}),
    do:
      assign(socket,
        outcome: %{"outcome" => "unknown", "operation_id" => socket.assigns.operation},
        error: error
      )

  defp verify(socket, receipt) do
    case Auth.request(socket, :privacy) do
      {:ok, privacy} ->
        if verified?(privacy, receipt) do
          assign(socket,
            privacy: privacy,
            generation: privacy["generation"],
            outcome: receipt,
            deleted: receipt,
            closed: true,
            error: nil
          )
        else
          unrelated(socket)
        end

      {:error, error} ->
        assign(socket,
          outcome: %{"outcome" => "unknown", "operation_id" => socket.assigns.operation},
          error: error
        )
    end
  end

  defp verified?(privacy, receipt) do
    data = receipt["data"]
    marker = privacy["last_deletion"]

    privacy?(privacy) and privacy["generation"] == receipt["generation"] and
      privacy["retained"] == @post_deletion and is_map(marker) and
      marker["generation"] == receipt["generation"] and
      marker["deleted_at"] == data["deleted_at"] and marker["removed"] == data["removed"]
  end

  defp privacy?(
         %{
           "schema" => "wtr.privacy.v1",
           "generation" => generation,
           "retained" => retained,
           "preserved_on_deletion" => preserved,
           "last_deletion" => last_deletion,
           "policy" => policy
         } = privacy
       ) do
    map_size(privacy) == 6 and generation?(generation) and
      count_map?(retained, @retained_keys) and count_map?(preserved, @preserved_keys) and
      deletion_marker?(last_deletion) and policy?(policy)
  end

  defp privacy?(_), do: false

  defp deletion_marker?(nil), do: true

  defp deletion_marker?(
         %{
           "schema" => "wtr.privacy-deletion.v1",
           "cause" => cause,
           "deleted_at" => deleted_at,
           "generation" => generation,
           "removed" => removed
         } = marker
       ),
       do:
         map_size(marker) == 5 and cause in ~w(administrator automatic_inactivity) and
           Codec.time?(deleted_at) and generation?(generation) and
           count_map?(removed, @retained_keys)

  defp deletion_marker?(_), do: false

  defp policy?(policy) when is_map(policy) and map_size(policy) == 9 do
    base = Map.drop(policy, ~w(domain_data inactivity_retention_ms enforcement_interval_ms))

    base == @base_policy and
      case policy do
        %{
          "domain_data" => "retained_until_administrator_deletion",
          "inactivity_retention_ms" => nil,
          "enforcement_interval_ms" => nil
        } ->
          true

        %{
          "domain_data" => "deleted_after_scope_inactivity",
          "inactivity_retention_ms" => retention,
          "enforcement_interval_ms" => interval
        } ->
          is_integer(retention) and retention in 1..31_536_000_000 and
            is_integer(interval) and interval in 1..86_400_000

        _ ->
          false
      end
  end

  defp policy?(_), do: false

  defp retention_description(%{
         "domain_data" => "deleted_after_scope_inactivity",
         "inactivity_retention_ms" => retention,
         "enforcement_interval_ms" => interval
       }) do
    "Domain data is automatically deleted after #{retention} ms without a domain mutation; " <>
      "the background check runs every #{interval} ms and access enforces the boundary immediately."
  end

  defp retention_description(_),
    do: "Domain data is retained until an administrator deletes it."

  defp deletion_cause(%{"cause" => "automatic_inactivity"}),
    do: "configured scope inactivity"

  defp deletion_cause(_), do: "administrator confirmation"

  defp committed_receipt?(
         %{
           "outcome" => "committed",
           "operation_id" => operation,
           "generation" => generation,
           "disposition" => "accepted",
           "publication" => nil,
           "data" => data
         } = receipt,
         operation
       ) do
    map_size(receipt) == 6 and generation?(generation) and deletion_data?(data)
  end

  defp committed_receipt?(_, _), do: false

  defp deletion_data?(
         %{
           "schema" => "wtr.domain-data-deletion.v1",
           "action" => "deleted_retained_domain_data",
           "deleted_at" => deleted_at,
           "removed" => removed,
           "preserved" => preserved,
           "backups" => "not_deleted",
           "offline_exports" => "not_deleted",
           "remote_publications" => "not_deleted"
         } = data
       ),
       do:
         map_size(data) == 8 and Codec.time?(deleted_at) and
           count_map?(removed, @retained_keys) and count_map?(preserved, @preserved_keys)

  defp deletion_data?(_), do: false

  defp unknown_receipt?(
         %{"outcome" => "unknown", "operation_id" => operation} = receipt,
         operation
       ),
       do: map_size(receipt) == 2

  defp unknown_receipt?(_, _), do: false

  defp count_map?(counts, keys) when is_map(counts),
    do:
      map_size(counts) == length(keys) and Enum.sort(Map.keys(counts)) == Enum.sort(keys) and
        Enum.all?(counts, fn {_, count} ->
          is_integer(count) and count in 0..9_007_199_254_740_991
        end)

  defp count_map?(_, _), do: false

  defp generation?(generation), do: match?({:ok, _}, Codec.generation(generation))

  defp retained_rows(nil), do: []

  defp retained_rows(privacy),
    do: rows(privacy["retained"], @retained_keys)

  defp preserved_rows(nil), do: []

  defp preserved_rows(privacy),
    do: rows(privacy["preserved_on_deletion"], @preserved_keys)

  defp rows(counts, keys), do: Enum.map(keys, &{label(&1), counts[&1]})

  defp label("record_versions"), do: "Versioned domain records"
  defp label("queued_deliveries"), do: "Queued deliveries"
  defp label("rule_states"), do: "Rule states"
  defp label("rule_event_intents"), do: "Rule event intents"
  defp label("operation_receipts"), do: "Operation receipts"
  defp label("credential_revocations"), do: "Credential revocations"
  defp label("successful_access_entries"), do: "Successful access entries"
  defp label(value), do: value |> String.replace("_", " ") |> String.capitalize()

  defp unrelated(socket),
    do:
      assign(socket,
        outcome: %{"outcome" => "unrelated"},
        deleted: nil,
        closed: true,
        error: %{"code" => "operation_mismatch"}
      )
end
