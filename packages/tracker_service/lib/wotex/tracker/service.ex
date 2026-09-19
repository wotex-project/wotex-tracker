defmodule Wotex.Tracker.Service do
  @moduledoc """
  Authenticated headless service facade over explicitly configured host resources.

  Every public operation takes an ephemeral bearer token and exact scope. The
  host supplies time; a wire adapter must never forward a request's clock as the
  authorization clock. Store, credential and model snapshots remain explicit.
  This facade starts no process, listener or physical ingress.
  """

  alias Wotex.Tracker.{Catalogue, Model, Observation, QuerySpec}
  alias Wotex.Tracker.Decoders.RuuviRawV2

  alias Wotex.Tracker.Service.{
    Alert,
    AnalyticsPage,
    Arming,
    Association,
    Codec,
    Credentials,
    Cursor,
    DecoderRegistry,
    Enrollment,
    Events,
    History,
    Identifier,
    Import,
    Interaction,
    Materialize,
    OwnerPresence,
    Projection,
    Result,
    RouteHistory,
    RuleDefinition,
    SavedQuery,
    Snapshot,
    Store,
    TripSummary,
    Unenrollment,
    Update
  }

  @maximum_time 9_007_199_254_740_991

  @resources ~w(observations resolutions evidence state enrollments things saved_queries rules policies alerts arming owner_presence)
  @derive {Inspect, only: [:base_url]}
  @enforce_keys [:store, :credentials, :catalogue, :model, :decoders, :base_url]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          store: Store.t(),
          credentials: Credentials.t(),
          catalogue: Catalogue.t(),
          model: Model.t(),
          decoders: %{
            required({String.t(), String.t()}) => (Observation.t() -> term())
          },
          base_url: String.t()
        }

  @doc "Builds a service using either the packaged RAWv2 contract or an exact trusted profile configuration."
  @spec new(map()) :: {:ok, t()} | {:error, atom()}
  def new(%{store: %Store{} = store, credentials: credentials, base_url: base} = input)
      when map_size(input) == 3 do
    with {:ok, profile} <- RuuviRawV2.profile(),
         {:ok, catalogue} <- Catalogue.new([profile]),
         {:ok, bytes} <-
           File.read(
             Application.app_dir(
               :wotex_tracker,
               "priv/thing_models/environmental-sensor-1.0.0.tm.json"
             )
           ),
         {:ok, document} <- Wotex.JSON.decode(bytes),
         {:ok, model} <- Model.new(document, profile.model) do
      configure(store, credentials, base, catalogue, model, [
        {RuuviRawV2.revision(), &RuuviRawV2.decode/1}
      ])
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  def new(
        %{
          store: %Store{} = store,
          credentials: credentials,
          base_url: base,
          catalogue: catalogue,
          model: model,
          decoders: decoders
        } = input
      )
      when map_size(input) == 6,
      do: configure(store, credentials, base, catalogue, model, decoders)

  def new(_), do: {:error, :invalid_configuration}

  defp configure(store, credentials, base, catalogue, model, configured) do
    with {:ok, credentials} <- Credentials.validate(credentials),
         {:ok, base} <- base_url(base),
         {:ok, catalogue} <- Catalogue.validate(catalogue),
         {:ok, model} <- Model.validate(model),
         true <- Enum.all?(catalogue.profiles, &(&1.model == model.revision)),
         {:ok, decoders} <- DecoderRegistry.new(catalogue, configured) do
      {:ok,
       %__MODULE__{
         store: store,
         credentials: credentials,
         catalogue: catalogue,
         model: model,
         decoders: decoders,
         base_url: base
       }}
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  @doc "Imports one WTR.01 envelope atomically with private evidence and public projections."
  @spec submit(t(), String.t(), String.t(), String.t(), map(), integer()) ::
          {:ok, map()} | {:error, map()}
  def submit(service, token, scope, operation, request, now) do
    result =
      with {:ok, access} <- authorize(service, token, scope, "ingest", now),
           true <- Identifier.operation?(operation),
           {:ok, observation} <- Import.admit(request) do
        {:ok, identity} = Observation.identity(observation)

        intent = %{
          operation_id: operation,
          request: %{"operation" => "import", "body" => request},
          expected_generation: request["expected_generation"],
          observation_identity: identity
        }

        execute_new(service, access, "ingest", intent, now, fn ->
          Import.prepare(service, access, operation, request, observation, now)
        end)
      else
        false -> {:error, :invalid_request}
        error -> error
      end

    Result.mutation(result, operation)
  end

  @doc "Enrolls a resolved observation with an explicit operator confirmation and fresh pseudonym."
  @spec enroll(t(), String.t(), String.t(), String.t(), map(), integer()) ::
          {:ok, map()} | {:error, map()}
  def enroll(service, token, scope, operation, request, now),
    do: resource_mutation(service, {token, scope, operation, request, now}, "enroll", Enrollment)

  @doc "Explicitly associates a resolved observation with an existing Thing; materialisation remains a separate conditional mutation."
  @spec associate(t(), String.t(), String.t(), String.t(), map(), integer()) ::
          {:ok, map()} | {:error, map()}
  def associate(service, token, scope, operation, request, now),
    do:
      resource_mutation(
        service,
        {token, scope, operation, request, now},
        "associate",
        Association
      )

  @doc "Materialises an enrolled snapshot through the pure core and durably records its validated TD."
  @spec materialize(t(), String.t(), String.t(), String.t(), map(), integer()) ::
          {:ok, map()} | {:error, map()}
  def materialize(service, token, scope, operation, request, now),
    do:
      resource_mutation(
        service,
        {token, scope, operation, request, now},
        "materialize",
        Materialize
      )

  @doc "Reads one declared scalar Property through Runtime using an authenticated immutable state snapshot."
  @spec read_property(
          t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          Wotex.Runtime.Context.t(),
          integer()
        ) ::
          {:ok, map()} | {:error, map()}
  def read_property(service, token, scope, thing, name, context, now) do
    result =
      with {:ok, access} <- authorize(service, token, scope, "read", now),
           do: Interaction.read(service, access, thing, name, context, now)

    Result.normalize(result)
  end

  @doc "Lists reviewed public projections at one snapshot with encrypted page and event cursors."
  @spec list(t(), String.t(), String.t(), String.t(), map(), integer()) ::
          {:ok, map()} | {:error, map()}
  def list(service, token, scope, resource, params, now) do
    result =
      with {:ok, access} <- authorize(service, token, scope, "read", now),
           :ok <- resource(resource),
           {:ok, query} <- page_query(service, access, resource, params, now),
           {:ok, page} <- Store.authorized_snapshot(service.store, access, "read", query, now) do
        page_result(service, access, resource, page, query.limit, now)
      end

    Result.normalize(result)
  end

  @doc "Gets one reviewed projection; untrusted callers never receive underlying store records."
  @spec get(t(), String.t(), String.t(), String.t(), String.t(), integer()) ::
          {:ok, map()} | {:error, map()}
  def get(service, token, scope, resource, id, now) do
    result =
      with {:ok, access} <- authorize(service, token, scope, "read", now),
           :ok <- resource(resource),
           {:ok, row} <- fetch(service, access, storage_kind(resource), id, nil, "read", now),
           {:ok, value} <- Projection.public(resource, id, row["value"]) do
        {:ok, %{"generation" => row["generation"], "id" => id, "value" => value}}
      end

    Result.normalize(result)
  end

  @doc "Lists immutable public resource versions at a bound snapshot, including deletion tombstones."
  @spec history(t(), String.t(), String.t(), String.t(), String.t(), map(), integer()) ::
          {:ok, map()} | {:error, map()}
  def history(service, token, scope, resource, id, params, now) do
    result =
      with {:ok, access} <- authorize(service, token, scope, "read", now),
           :ok <- resource(resource),
           do: History.page(service, access, resource, id, params, now)

    Result.normalize(result)
  end

  @doc "Executes one closed numeric history query against an authorized committed snapshot."
  @spec analytics(t(), String.t(), String.t(), map(), integer()) ::
          {:ok, map()} | {:error, map()}
  def analytics(service, token, scope, document, now) do
    result =
      with {:ok, access} <- authorize(service, token, scope, "read", now),
           {:ok, spec} <- query_spec(document),
           do: Store.authorized_analytics(service.store, access, spec, now)

    Result.normalize(result)
  end

  @doc "Pages one closed numeric history query at a cursor-bound committed generation."
  @spec analytics_page(t(), String.t(), String.t(), map(), integer()) ::
          {:ok, map()} | {:error, map()}
  def analytics_page(service, token, scope, request, now) do
    result =
      with {:ok, access} <- authorize(service, token, scope, "read", now),
           do: AnalyticsPage.run(service, access, request, now)

    Result.normalize(result)
  end

  @doc "Pages one gap-honest route projection from private retained position evidence."
  @spec route_history(t(), String.t(), String.t(), map(), integer()) ::
          {:ok, map()} | {:error, map()}
  def route_history(service, token, scope, request, now) do
    result =
      with {:ok, access} <- authorize(service, token, scope, "read", now),
           do: RouteHistory.run(service, access, request, now)

    Result.normalize(result)
  end

  @doc "Saves one admitted absolute or rolling query and its closed visualization options."
  @spec save_query(t(), String.t(), String.t(), String.t(), map(), integer()) ::
          {:ok, map()} | {:error, map()}
  def save_query(service, token, scope, operation, request, now),
    do:
      admin_mutation(service, {token, scope, operation, request, now}, SavedQuery, :save, "query")

  @doc "Deletes one owned saved query through a retained transactional tombstone."
  @spec delete_query(t(), String.t(), String.t(), String.t(), map(), integer()) ::
          {:ok, map()} | {:error, map()}
  def delete_query(service, token, scope, operation, request, now),
    do:
      admin_mutation(
        service,
        {token, scope, operation, request, now},
        SavedQuery,
        :delete,
        "query"
      )

  @doc "Saves one closed rule definition for an enrolled Thing."
  @spec save_policy(t(), String.t(), String.t(), String.t(), map(), integer()) ::
          {:ok, map()} | {:error, map()}
  def save_policy(service, token, scope, operation, request, now),
    do:
      admin_mutation(
        service,
        {token, scope, operation, request, now},
        RuleDefinition,
        :save,
        "policy"
      )

  @doc "Deletes one rule definition through a retained transactional tombstone."
  @spec delete_policy(t(), String.t(), String.t(), String.t(), map(), integer()) ::
          {:ok, map()} | {:error, map()}
  def delete_policy(service, token, scope, operation, request, now),
    do:
      admin_mutation(
        service,
        {token, scope, operation, request, now},
        RuleDefinition,
        :delete,
        "policy"
      )

  @doc "Commits one explicit armed or disarmed fact for an enrolled Thing."
  @spec set_arming(t(), String.t(), String.t(), String.t(), map(), integer()) ::
          {:ok, map()} | {:error, map()}
  def set_arming(service, token, scope, operation, request, now),
    do:
      admin_mutation(
        service,
        {token, scope, operation, request, now},
        Arming,
        :set,
        "arming"
      )

  @doc "Admits one closed owner-presence fact for an enrolled Thing."
  @spec admit_owner_presence(t(), String.t(), String.t(), String.t(), map(), integer()) ::
          {:ok, map()} | {:error, map()}
  def admit_owner_presence(service, token, scope, operation, request, now),
    do:
      admin_mutation(
        service,
        {token, scope, operation, request, now},
        OwnerPresence,
        :admit,
        "owner_presence"
      )

  @doc """
  Removes one enrolled asset from current views through an idempotent administrative mutation.

  The request has exactly `thing_id` and `expected_generation`. The enrollment,
  Thing, current state and every live rule definition bound to the Thing become
  deletion tombstones in one commit, so those rules stop scheduling. Record
  history, private evidence, observations and alerts are retained, and no
  publication or physical Action is requested.
  """
  @spec unenroll(t(), String.t(), String.t(), String.t(), map(), integer()) ::
          {:ok, map()} | {:error, map()}
  def unenroll(service, token, scope, operation, request, now),
    do:
      admin_mutation(
        service,
        {token, scope, operation, request, now},
        Unenrollment,
        :delete,
        "enrollment"
      )

  @doc "Lists the at most eight live rule definitions bound to one Thing at the current snapshot."
  @spec thing_policies(t(), String.t(), String.t(), String.t(), integer()) ::
          {:ok, map()} | {:error, map()}
  def thing_policies(service, token, scope, thing, now) do
    result =
      with {:ok, access} <- authorize(service, token, scope, "read", now),
           {:ok, page} <-
             Store.authorized_policies(service.store, access, "read", thing, nil, now) do
        {:ok,
         %{
           page
           | "items" =>
               Enum.map(page["items"], fn row ->
                 %{row | "value" => Projection.resource("policies", row["value"])}
               end)
         }}
      end

    Result.normalize(result)
  end

  @doc """
  Reads the committed status of every rule defined for one Thing at one snapshot.

  Requires `read`. Items follow the Thing's live definitions in ID order, are
  identified as `kind:id` and carry the reviewed rule status projection read at the
  same generation as the definitions. A definition without recorded status is
  omitted; an unknown Thing has none.
  """
  @spec thing_rules(t(), String.t(), String.t(), String.t(), integer()) ::
          {:ok, map()} | {:error, map()}
  def thing_rules(service, token, scope, thing, now) do
    result =
      with {:ok, access} <- authorize(service, token, scope, "read", now),
           {:ok, page} <-
             Store.authorized_policies(service.store, access, "read", thing, nil, now),
           {:ok, items} <- rule_statuses(service, access, page, now) do
        {:ok, %{"generation" => page["generation"], "items" => items}}
      end

    Result.normalize(result)
  end

  @doc """
  Pages, newest first, the alerts of rules defined for one Thing at a bound snapshot.

  Requires `read`. `params` accepts `limit` (1 to 100, default 25) and a
  `cursor` issued for the same Thing. Alerts of host-managed and event-only rules
  have no Thing and are not listed; an unknown Thing has none.
  """
  @spec thing_alerts(t(), String.t(), String.t(), String.t(), map(), integer()) ::
          {:ok, map()} | {:error, map()}
  def thing_alerts(service, token, scope, thing, params, now) do
    result =
      with {:ok, access} <- authorize(service, token, scope, "read", now),
           {:ok, query} <- thing_alert_query(service, access, thing, params, now),
           {:ok, page} <- Store.authorized_snapshot(service.store, access, "read", query, now),
           {:ok, items} <- Projection.public_items("alerts", page["items"]) do
        document = page_document(service, access, "alerts", page, items, query.limit, now)

        {:ok,
         %{document | "cursor" => thing_next(service, access, thing, page, query.limit, now)}}
      end

    Result.normalize(result)
  end

  @doc """
  Pages, newest first, the retained trip lifecycle events for one Thing.

  Requires `read`. Only `trip.started`, `trip.stopped` and `trip.interrupted`
  alerts are included. The cursor binds the caller, Thing, snapshot and page
  size; unrelated alerts cannot consume a page.
  """
  @spec thing_trips(t(), String.t(), String.t(), String.t(), map(), integer()) ::
          {:ok, map()} | {:error, map()}
  def thing_trips(service, token, scope, thing, params, now) do
    result =
      with {:ok, access} <- authorize(service, token, scope, "read", now),
           {:ok, query} <- thing_trip_query(service, access, thing, params, now),
           {:ok, page} <- Store.authorized_snapshot(service.store, access, "read", query, now),
           {:ok, items} <- Projection.public_items("alerts", page["items"]) do
        document = page_document(service, access, "alerts", page, items, query.limit, now)

        {:ok, %{document | "cursor" => thing_trip_next(service, access, thing, page, query, now)}}
      end

    Result.normalize(result)
  end

  @doc "Reconstructs one completed trip's bounded, public distance summary."
  @spec trip_summary(t(), String.t(), String.t(), String.t(), String.t(), integer()) ::
          {:ok, map()} | {:error, map()}
  def trip_summary(service, token, scope, thing, trip, now) do
    result =
      with {:ok, access} <- authorize(service, token, scope, "read", now),
           do: TripSummary.run(service, access, thing, trip, now)

    Result.normalize(result)
  end

  @doc "Acknowledges one live rule alert once without changing rule state or dispatching an Action."
  @spec acknowledge_alert(t(), String.t(), String.t(), String.t(), map(), integer()) ::
          {:ok, map()} | {:error, map()}
  def acknowledge_alert(service, token, scope, operation, request, now),
    do:
      admin_mutation(
        service,
        {token, scope, operation, request, now},
        Alert,
        :acknowledge,
        "alert"
      )

  @doc "Executes the admitted query from a saved definition after current read authorization."
  @spec execute_saved_query(t(), String.t(), String.t(), String.t(), integer()) ::
          {:ok, map()} | {:error, map()}
  def execute_saved_query(service, token, scope, id, now) do
    result =
      with {:ok, access} <- authorize(service, token, scope, "read", now),
           {:ok, row} <- fetch(service, access, "saved_queries", id, nil, "read", now),
           {:ok, spec} <- SavedQuery.query(row["value"], id, now),
           {:ok, pin} <- SavedQuery.pin(row["value"], id),
           do: run_saved(service, access, spec, pin, now)

    Result.normalize(result)
  end

  @doc "Exports native observation JSON bytes only with the raw-evidence grant."
  @spec raw_observation(t(), String.t(), String.t(), String.t(), integer()) ::
          {:ok, binary()} | {:error, map()}
  def raw_observation(service, token, scope, id, now) do
    result =
      with {:ok, access} <- authorize(service, token, scope, "raw", now),
           {:ok, index} <- fetch(service, access, "resolutions", id, nil, "raw", now),
           {:ok, row} <-
             fetch(
               service,
               access,
               "observations",
               index["value"]["observation_id"],
               index["generation"],
               "raw",
               now
             ),
           {:ok, document} <- stored_observation(row["value"]) do
        Codec.encode(document)
      end

    Result.normalize(result)
  end

  @doc "Exports full native evidence claims only through the separate raw-evidence permission."
  @spec raw_evidence(t(), String.t(), String.t(), String.t(), integer()) ::
          {:ok, binary()} | {:error, map()}
  def raw_evidence(service, token, scope, id, now) do
    result =
      with {:ok, access} <- authorize(service, token, scope, "raw", now),
           {:ok, row} <- fetch(service, access, "evidence", id, nil, "raw", now) do
        Codec.encode(row["value"]["claims"])
      end

    Result.normalize(result)
  end

  @doc "Reads durable events using a bound cursor; stable domain IDs are independent of transport cursors."
  @spec events(t(), String.t(), String.t(), String.t(), integer()) ::
          {:ok, map()} | {:error, map()}
  def events(service, token, scope, cursor, now) do
    result =
      with {:ok, access} <- authorize(service, token, scope, "read", now),
           do: Events.batch(service, access, cursor, now)

    Result.normalize(result)
  end

  @doc """
  Lists this scope's configured credentials with grants, expiry and durable revocation.

  Requires `admin` and reads revocations at the current committed generation.
  Items include credential IDs and principals so an administrator can audit and
  revoke access; they omit token digests and other scopes' grants. `status` is
  `revoked`, `expired` at the supplied receiver time, or `active`, and `current`
  marks the calling credential. A revocation whose ID no longer appears in the
  host configuration is not listed.
  """
  @spec credentials(t(), String.t(), String.t(), integer()) :: {:ok, map()} | {:error, map()}
  def credentials(service, token, scope, now) do
    result =
      with {:ok, access} <- authorize(service, token, scope, "admin", now),
           entries = Credentials.inventory(service.credentials, scope),
           {:ok, page} <-
             Store.authorized_revocations(
               service.store,
               access,
               Enum.map(entries, & &1.id),
               now
             ) do
        revocations = Map.new(page["items"], &{&1["id"], &1})

        {:ok,
         %{
           "generation" => page["generation"],
           "items" => Enum.map(entries, &credential(&1, revocations[&1.id], access, now))
         }}
      end

    Result.normalize(result)
  end

  @doc "Permanently revokes a credential ID in this scope through an idempotent administrative mutation."
  @spec revoke(t(), String.t(), String.t(), String.t(), map(), integer()) ::
          {:ok, map()} | {:error, map()}
  def revoke(service, token, scope, operation, request, now) do
    result =
      with {:ok, access} <- authorize(service, token, scope, "admin", now),
           true <- Identifier.operation?(operation),
           %{"credential_id" => id, "expected_generation" => generation}
           when map_size(request) == 2 <- request,
           true <- Codec.id?(id),
           {:ok, _} <- Codec.generation(generation),
           {:ok, update} <-
             Update.new(%{
               principal: access.principal,
               scope: scope,
               authority: access,
               operation_id: operation,
               now: now,
               expected_generation: generation,
               request: %{"operation" => "revoke", "body" => request},
               observation: nil,
               publication: nil,
               response: %{"credential_id" => id},
               records: [
                 %{
                   kind: "access",
                   id: id,
                   value: %{"revoked" => true, "at" => now, "actor" => access.principal}
                 }
               ],
               events: [
                 %{
                   "type" => "access.revoked",
                   "data" => %{
                     "id" => Projection.pseudonym(service.credentials, scope, "credential", id)
                   }
                 }
               ]
             }) do
        Store.mutate(service.store, update)
      else
        {:error, _} = error -> error
        _ -> {:error, :invalid_request}
      end

    Result.mutation(result, operation)
  end

  @doc "Resolves a caller-scoped operation outcome without re-executing the mutation."
  @spec operation(t(), String.t(), String.t(), String.t(), integer()) ::
          {:ok, map()} | {:error, map()}
  def operation(service, token, scope, id, now) do
    result =
      with {:ok, access} <- authorize(service, token, scope, "read", now),
           true <- Identifier.operation?(id) do
        Store.authorized_operation(service.store, access, id, now)
      else
        false -> {:error, :invalid_request}
        error -> error
      end

    Result.normalize(result)
  end

  @doc """
  Pages the caller's own unexpired operation receipts in this scope, newest first.

  Requires `read`. `params` accepts `limit` (1 to 100, default 25) and a `cursor`
  that binds the first page's generation, so later commits are excluded. Each
  item carries the operation ID, commit generation, recording and expiry times
  and the stored receipt. Receipts of other principals and expired receipts are
  never listed; only committed outcomes have receipts.
  """
  @spec operations(t(), String.t(), String.t(), map(), integer()) ::
          {:ok, map()} | {:error, map()}
  def operations(service, token, scope, params, now) do
    result =
      with {:ok, access} <- authorize(service, token, scope, "read", now),
           {:ok, query} <- operation_query(service, access, params, now),
           {:ok, page} <- Store.authorized_operations(service.store, access, query, now) do
        {:ok,
         %{
           "generation" => page["generation"],
           "items" => page["items"],
           "cursor" => operation_cursor(service, access, page, query.limit, now)
         }}
      end

    Result.normalize(result)
  end

  @doc "Authenticates current scope authority; transports must repeat this before every delivery."
  @spec authorize(t(), term(), term(), String.t(), integer()) ::
          {:ok, Wotex.Tracker.Service.Access.t()} | {:error, atom()}
  def authorize(service, token, scope, permission, now) do
    with {:ok, access} <-
           Credentials.authenticate(service.credentials, token, scope, permission, now),
         :ok <- Store.authorized(service.store, access, permission, now) do
      {:ok, access}
    else
      {:error, :unknown} -> {:error, :storage_unavailable}
      error -> error
    end
  end

  defp credential(entry, revocation, access, now) do
    status =
      cond do
        revocation -> "revoked"
        now >= entry.expires_at -> "expired"
        true -> "active"
      end

    %{
      "schema" => "wtr.credential.v1",
      "credential_id" => entry.id,
      "principal" => entry.principal,
      "permissions" => entry.permissions,
      "expires_at" => entry.expires_at,
      "status" => status,
      "current" => entry.id == access.credential_id,
      "revocation" =>
        revocation &&
          %{
            "at" => revocation["value"]["at"],
            "by" => revocation["value"]["actor"],
            "generation" => revocation["generation"]
          }
    }
  end

  defp resource(resource) when resource in @resources, do: :ok
  defp resource(_), do: {:error, :unsupported}

  defp resource_mutation(service, {token, scope, operation, request, now}, kind, implementation) do
    result =
      with {:ok, access} <- authorize(service, token, scope, "enroll", now),
           true <- Identifier.operation?(operation),
           :ok <- implementation.admit(request) do
        intent = %{
          operation_id: operation,
          request: %{"operation" => kind, "body" => request},
          expected_generation: request["expected_generation"],
          observation_identity: nil
        }

        execute_new(service, access, "enroll", intent, now, fn ->
          implementation.prepare(service, access, operation, request, now)
        end)
      else
        false -> {:error, :invalid_request}
        error -> error
      end

    Result.mutation(result, operation)
  end

  defp execute_new(service, access, permission, intent, now, prepare) do
    case Store.replay(service.store, access, permission, intent, now) do
      :new ->
        with {:ok, update} <- prepare.(), do: Store.mutate(service.store, update)

      {:error, :unknown} ->
        {:error, :storage_unavailable}

      result ->
        result
    end
  end

  defp admin_mutation(service, {token, scope, operation, request, now}, module, action, name) do
    result =
      with {:ok, access} <- authorize(service, token, scope, "admin", now),
           true <- Identifier.operation?(operation),
           :ok <- admit_admin(module, action, request) do
        intent = %{
          operation_id: operation,
          request: %{"operation" => "#{action}_#{name}", "body" => request},
          expected_generation: request["expected_generation"],
          observation_identity: nil
        }

        execute_new(service, access, "admin", intent, now, fn ->
          prepare_admin(module, action, service, access, operation, request, now)
        end)
      else
        false -> {:error, :invalid_request}
        error -> error
      end

    Result.mutation(result, operation)
  end

  defp admit_admin(module, :save, request), do: module.admit_save(request)
  defp admit_admin(module, :delete, request), do: module.admit_delete(request)
  defp admit_admin(module, :acknowledge, request), do: module.admit_acknowledge(request)
  defp admit_admin(module, :set, request), do: module.admit_set(request)
  defp admit_admin(module, :admit, request), do: module.admit(request)

  defp prepare_admin(module, :save, service, access, operation, request, now),
    do: module.prepare_save(service, access, operation, request, now)

  defp prepare_admin(module, :delete, service, access, operation, request, now),
    do: module.prepare_delete(service, access, operation, request, now)

  defp prepare_admin(module, :acknowledge, service, access, operation, request, now),
    do: module.prepare_acknowledge(service, access, operation, request, now)

  defp prepare_admin(module, :set, service, access, operation, request, now),
    do: module.prepare_set(service, access, operation, request, now)

  defp prepare_admin(module, :admit, service, access, operation, request, now),
    do: module.prepare(service, access, operation, request, now)

  defp storage_kind("observations"), do: "resolutions"
  defp storage_kind(resource), do: resource

  defp fetch(service, access, kind, id, generation, permission, now),
    do: Snapshot.fetch(service, access, kind, id, generation, permission, now)

  defp page_query(service, access, resource, params, now)
       when is_map(params) and map_size(params) <= 2 do
    if Enum.all?(Map.keys(params), &(&1 in ["limit", "cursor"])) do
      cursor_query(service, access, resource, params, now)
    else
      {:error, :invalid_request}
    end
  end

  defp page_query(_, _, _, _, _), do: {:error, :invalid_request}

  defp cursor_query(service, access, resource, %{"cursor" => cursor} = params, now) do
    with {:ok, data} <-
           Cursor.open(
             Credentials.derive_key(service.credentials, :cursor),
             binding(service, access, "page"),
             cursor,
             now
           ),
         true <-
           data["kind"] == resource and Map.get(params, "limit", data["limit"]) == data["limit"] do
      {:ok,
       %{
         scope: access.scope,
         kind: storage_kind(resource),
         generation: data["generation"],
         after: data["after"],
         limit: data["limit"]
       }}
    else
      false -> {:error, :invalid_cursor}
      error -> error
    end
  end

  defp cursor_query(_service, access, resource, params, _now) do
    limit = Map.get(params, "limit", 25)

    if is_integer(limit) and limit in 1..100,
      do:
        {:ok,
         %{
           scope: access.scope,
           kind: storage_kind(resource),
           generation: nil,
           after: "",
           limit: limit
         }},
      else: {:error, :invalid_request}
  end

  defp run_saved(service, access, spec, nil, now),
    do: Store.authorized_analytics(service.store, access, spec, now)

  # An incident snapshot reruns at its pinned generation and must reproduce its result.
  defp run_saved(service, access, spec, {generation, identity}, now) do
    case Store.authorized_analytics_at(service.store, access, spec, now, generation) do
      {:ok, %{"identity" => ^identity} = result} -> {:ok, result}
      {:ok, _} -> {:error, :revision_mismatch}
      error -> error
    end
  end

  # Each status is read at the definitions' generation, so the list is one snapshot.
  defp rule_statuses(service, access, page, now) do
    page["items"]
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, statuses} ->
      id = row["value"]["public"]["kind"] <> ":" <> row["id"]

      with {:ok, status} <- fetch(service, access, "rules", id, page["generation"], "read", now),
           {:ok, value} <- Projection.public("rules", id, status["value"]) do
        {:cont, {:ok, [%{"id" => id, "value" => value} | statuses]}}
      else
        {:error, :not_found} -> {:cont, {:ok, statuses}}
        error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, statuses} -> {:ok, Enum.reverse(statuses)}
      error -> error
    end)
  end

  defp operation_query(service, access, %{"cursor" => cursor} = params, now)
       when map_size(params) <= 2 do
    with true <- Enum.all?(Map.keys(params), &(&1 in ["limit", "cursor"])),
         {:ok, data} <-
           Cursor.open(
             Credentials.derive_key(service.credentials, :cursor),
             binding(service, access, "page"),
             cursor,
             now
           ),
         true <-
           data["kind"] == "operations" and
             Map.get(params, "limit", data["limit"]) == data["limit"] do
      {:ok, %{generation: data["generation"], after: data["after"], limit: data["limit"]}}
    else
      false -> {:error, :invalid_cursor}
      error -> error
    end
  end

  defp operation_query(_service, _access, params, _now)
       when is_map(params) and map_size(params) <= 1 do
    limit = Map.get(params, "limit", 25)

    if Enum.all?(Map.keys(params), &(&1 == "limit")) and is_integer(limit) and limit in 1..100,
      do: {:ok, %{generation: nil, after: nil, limit: limit}},
      else: {:error, :invalid_request}
  end

  defp operation_query(_, _, _, _), do: {:error, :invalid_request}

  defp operation_cursor(_service, _access, %{"next" => nil}, _limit, _now), do: nil

  defp operation_cursor(service, access, page, limit, now) do
    {:ok, cursor} =
      Cursor.issue(
        Credentials.derive_key(service.credentials, :cursor),
        binding(service, access, "page"),
        %{
          "kind" => "operations",
          "generation" => page["generation"],
          "after" => page["next"],
          "limit" => limit
        },
        now
      )

    cursor
  end

  # A Thing's alert cursor binds that Thing, so a page cannot continue for another one.
  defp thing_alert_query(service, access, thing, %{"cursor" => cursor} = params, now)
       when map_size(params) <= 2 do
    with true <- Codec.id?(thing) and Enum.all?(Map.keys(params), &(&1 in ["limit", "cursor"])),
         {:ok, data} <-
           Cursor.open(
             Credentials.derive_key(service.credentials, :cursor),
             binding(service, access, "page"),
             cursor,
             now
           ),
         true <-
           data["kind"] == "thing_alerts" and data["thing"] == thing and
             Map.get(params, "limit", data["limit"]) == data["limit"] do
      {:ok,
       %{
         scope: access.scope,
         kind: "alerts",
         generation: data["generation"],
         after: data["after"],
         limit: data["limit"],
         thing: thing
       }}
    else
      false -> {:error, :invalid_cursor}
      error -> error
    end
  end

  defp thing_alert_query(service, access, thing, params, now) do
    with true <- Codec.id?(thing),
         {:ok, query} <- page_query(service, access, "alerts", params, now) do
      {:ok, Map.put(query, :thing, thing)}
    else
      false -> {:error, :invalid_query}
      error -> error
    end
  end

  defp thing_next(_service, _access, _thing, %{"next" => nil}, _limit, _now), do: nil

  defp thing_next(service, access, thing, page, limit, now) do
    {:ok, next} =
      Cursor.issue(
        Credentials.derive_key(service.credentials, :cursor),
        binding(service, access, "page"),
        %{
          "kind" => "thing_alerts",
          "thing" => thing,
          "generation" => page["generation"],
          "after" => page["next"],
          "limit" => limit
        },
        now
      )

    next
  end

  defp thing_trip_query(service, access, thing, %{"cursor" => cursor} = params, now)
       when map_size(params) <= 2 do
    with true <- Codec.id?(thing) and Enum.all?(Map.keys(params), &(&1 in ["limit", "cursor"])),
         {:ok, data} <-
           Cursor.open(
             Credentials.derive_key(service.credentials, :cursor),
             binding(service, access, "page"),
             cursor,
             now
           ),
         true <-
           data["kind"] == "thing_trips" and data["thing"] == thing and
             Map.get(params, "limit", data["limit"]) == data["limit"] do
      {:ok,
       %{
         scope: access.scope,
         kind: "alerts",
         generation: data["generation"],
         after: data["after"],
         limit: data["limit"],
         thing: thing,
         event_kinds: ~w(trip.started trip.stopped trip.interrupted),
         from_at: data["from_at"],
         to_at: data["to_at"]
       }}
    else
      false -> {:error, :invalid_cursor}
      error -> error
    end
  end

  defp thing_trip_query(_service, access, thing, params, _now) do
    if Codec.id?(thing),
      do: thing_trip_first_query(access, thing, params),
      else: {:error, :invalid_query}
  end

  defp thing_trip_first_query(access, thing, params)
       when is_map(params) and not is_struct(params) do
    with true <- Enum.all?(Map.keys(params), &(&1 in ["limit", "from_at", "to_at"])),
         limit = Map.get(params, "limit", 25),
         true <- is_integer(limit) and limit in 1..100,
         {:ok, {from_at, to_at}} <- trip_window(params) do
      {:ok,
       %{
         scope: access.scope,
         kind: "alerts",
         generation: nil,
         after: "",
         limit: limit
       }
       |> Map.put(:thing, thing)
       |> Map.put(:event_kinds, ~w(trip.started trip.stopped trip.interrupted))
       |> Map.put(:from_at, from_at)
       |> Map.put(:to_at, to_at)}
    else
      false -> {:error, :invalid_request}
      error -> error
    end
  end

  defp thing_trip_first_query(_access, _thing, _params), do: {:error, :invalid_request}

  defp trip_window(%{"from_at" => from_at, "to_at" => to_at}) do
    if Codec.time?(from_at) and Codec.time?(to_at) and from_at < to_at,
      do: {:ok, {from_at, to_at}},
      else: {:error, :invalid_request}
  end

  defp trip_window(params) do
    if Map.has_key?(params, "from_at") or Map.has_key?(params, "to_at"),
      do: {:error, :invalid_request},
      else: {:ok, {0, @maximum_time}}
  end

  defp thing_trip_next(_service, _access, _thing, %{"next" => nil}, _query, _now), do: nil

  defp thing_trip_next(service, access, thing, page, query, now) do
    {:ok, next} =
      Cursor.issue(
        Credentials.derive_key(service.credentials, :cursor),
        binding(service, access, "page"),
        %{
          "kind" => "thing_trips",
          "thing" => thing,
          "generation" => page["generation"],
          "after" => page["next"],
          "limit" => query.limit,
          "from_at" => query.from_at,
          "to_at" => query.to_at
        },
        now
      )

    next
  end

  defp page_result(service, access, resource, page, limit, now) do
    with {:ok, items} <- Projection.public_items(resource, page["items"]),
         do: {:ok, page_document(service, access, resource, page, items, limit, now)}
  end

  defp page_document(service, access, resource, page, items, limit, now) do
    key = Credentials.derive_key(service.credentials, :cursor)

    next =
      if page["next"] do
        {:ok, next} =
          Cursor.issue(
            key,
            binding(service, access, "page"),
            %{
              "kind" => resource,
              "generation" => page["generation"],
              "after" => page["next"],
              "limit" => limit
            },
            now
          )

        next
      end

    {:ok, stream} =
      Cursor.issue(
        key,
        binding(service, access, "events"),
        %{
          "kind" => "events",
          "generation" => page["generation"],
          "after" => page["event_cursor"],
          "snapshot_generation" => page["generation"],
          "limit" => 100
        },
        now
      )

    %{
      "items" => items,
      "generation" => page["generation"],
      "cursor" => next,
      "stream_cursor" => stream
    }
  end

  defp binding(service, access, purpose),
    do: %{
      instance: Credentials.instance_id(service.credentials),
      principal: access.principal,
      scope: access.scope,
      purpose: purpose
    }

  defp stored_observation(document) do
    with {:ok, observation} <- Observation.from_map(document),
         {:ok, document} <- Observation.to_map(observation) do
      {:ok, document}
    else
      _ -> {:error, :storage_unavailable}
    end
  end

  defp query_spec(document) do
    case QuerySpec.from_map(document) do
      {:ok, spec} -> {:ok, spec}
      {:error, _} -> {:error, :invalid_request}
    end
  end

  defp base_url(value) when is_binary(value) and byte_size(value) in 1..2048 do
    with {:ok, uri} <- URI.new(String.trim_trailing(value, "/")),
         true <- valid_origin?(uri) and unadorned?(uri) do
      {:ok, URI.to_string(uri)}
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  defp base_url(_), do: {:error, :invalid_configuration}

  defp valid_origin?(uri),
    do:
      uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
        is_integer(uri.port) and uri.port in 1..65_535

  defp unadorned?(uri),
    do:
      is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) and
        uri.path in [nil, ""]
end
