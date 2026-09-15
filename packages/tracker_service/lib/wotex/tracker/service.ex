defmodule Wotex.Tracker.Service do
  @moduledoc """
  Authenticated headless service facade over explicitly configured host resources.

  Every public operation takes an ephemeral bearer token and exact scope. The
  host supplies time; a wire adapter must never forward a request's clock as the
  authorization clock. Store, credential and model snapshots remain explicit.
  This facade starts no process, listener or physical ingress.
  """
  alias Wotex.Tracker.{Catalogue, Model, Observation}
  alias Wotex.Tracker.Decoders.RuuviRawV2

  alias Wotex.Tracker.Service.{
    Codec,
    Credentials,
    Cursor,
    Enrollment,
    Events,
    Identifier,
    Import,
    Materialize,
    Projection,
    Result,
    Snapshot,
    Store,
    Update
  }

  @resources ~w(observations resolutions evidence state enrollments things)
  @derive {Inspect, only: [:base_url]}
  @enforce_keys [:store, :credentials, :catalogue, :model, :base_url]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          store: Store.t(),
          credentials: Credentials.t(),
          catalogue: Catalogue.t(),
          model: Model.t(),
          base_url: String.t()
        }

  @doc "Builds a service using the packaged RAWv2 catalogue/model and explicit host resources."
  @spec new(map()) :: {:ok, t()} | {:error, atom()}
  def new(%{store: %Store{} = store, credentials: credentials, base_url: base} = input)
      when map_size(input) == 3 do
    with {:ok, credentials} <- Credentials.validate(credentials),
         {:ok, base} <- base_url(base),
         {:ok, profile} <- RuuviRawV2.profile(),
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
      {:ok,
       %__MODULE__{
         store: store,
         credentials: credentials,
         catalogue: catalogue,
         model: model,
         base_url: base
       }}
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  def new(_), do: {:error, :invalid_configuration}

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
           {:ok, row} <- fetch(service, access, storage_kind(resource), id, nil, "read", now) do
        {:ok,
         %{
           "generation" => row["generation"],
           "id" => id,
           "value" => public(resource, row["value"])
         }}
      end

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

  defp storage_kind("observations"), do: "resolutions"
  defp storage_kind(resource), do: resource
  defp public("observations", value), do: value["public"]["observation"]
  defp public("resolutions", value), do: value["public"]["resolution"]
  defp public(_, value), do: value["public"]

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

  defp page_result(service, access, resource, page, limit, now) do
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

    items =
      Enum.map(page["items"], fn row -> %{row | "value" => public(resource, row["value"])} end)

    {:ok,
     %{
       "items" => items,
       "generation" => page["generation"],
       "cursor" => next,
       "stream_cursor" => stream
     }}
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
