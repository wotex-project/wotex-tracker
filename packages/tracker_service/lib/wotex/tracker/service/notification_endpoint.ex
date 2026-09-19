defmodule Wotex.Tracker.Service.NotificationEndpoint do
  @moduledoc false

  # A push token is private routing material. It is encrypted before entering
  # the generic record store, while the public projection remains sufficient
  # for an administrator to distinguish and rotate an app installation.

  alias Wotex.Tracker.Service.{Codec, Credentials, Projection, Store, Update}

  @register_fields ~w(id provider app_id environment token expected_generation)
  @unregister_fields ~w(id expected_generation)
  @public_fields ~w(schema id provider app_id environment revision created_at updated_at)
  @stored_fields ~w(owner secret public)
  @providers ~w(apns)
  @environments ~w(sandbox production)
  @maximum_endpoints 8

  def admit_register(request) do
    with true <- exact?(request, @register_fields),
         true <- Enum.all?([request["id"], request["app_id"]], &Codec.id?/1),
         true <- request["provider"] in @providers,
         true <- request["environment"] in @environments,
         true <- token?(request["token"]),
         {:ok, _generation} <- Codec.generation(request["expected_generation"]) do
      :ok
    else
      _ -> {:error, :invalid_request}
    end
  end

  def admit_unregister(request) do
    with true <- exact?(request, @unregister_fields),
         true <- Codec.id?(request["id"]),
         {:ok, _generation} <- Codec.generation(request["expected_generation"]) do
      :ok
    else
      _ -> {:error, :invalid_request}
    end
  end

  def prepare_register(service, access, operation, request, now) do
    internal_id = internal_id(service, access, request["id"])

    with {:ok, created_at} <- existing_or_capacity(service, access, internal_id, request, now),
         {:ok, secret} <- seal(service, access, internal_id, request) do
      {:ok, generation} = Codec.generation(request["expected_generation"])

      public = %{
        "schema" => "wtr.notification-endpoint.v1",
        "id" => request["id"],
        "provider" => request["provider"],
        "app_id" => request["app_id"],
        "environment" => request["environment"],
        "revision" => "notification-endpoint-" <> Integer.to_string(generation + 1),
        "created_at" => created_at,
        "updated_at" => now
      }

      update(
        service,
        access,
        operation,
        request,
        now,
        internal_id,
        %{"owner" => access.principal, "secret" => secret, "public" => public},
        "registered"
      )
    end
  end

  def prepare_unregister(service, access, operation, request, now) do
    internal_id = internal_id(service, access, request["id"])

    with {:ok, %{"value" => value}} <- current(service, access, internal_id, request, now),
         {:ok, _public} <- project(service, access, internal_id, value) do
      update(service, access, operation, request, now, internal_id, nil, "unregistered")
    end
  end

  @doc false
  def list(service, access, generation, now) do
    with {:ok, page} <-
           Store.authorized_notification_endpoints(
             service.store,
             access,
             generation,
             @maximum_endpoints + 1,
             now
           ),
         true <- length(page["items"]) <= @maximum_endpoints,
         {:ok, items} <- project_items(service, access, page["items"]) do
      {:ok, %{"generation" => page["generation"], "items" => items}}
    else
      false -> {:error, :storage_unavailable}
      error -> error
    end
  end

  @doc false
  def fetch(service, access, id, now) do
    internal_id = internal_id(service, access, id)

    with {:ok, row} <-
           Store.authorized_fetch(
             service.store,
             access,
             "admin",
             %{
               scope: access.scope,
               kind: "notification_endpoints",
               id: internal_id,
               generation: nil
             },
             now
           ),
         {:ok, public} <- project(service, access, internal_id, row["value"]) do
      {:ok,
       %{
         "generation" => row["generation"],
         "id" => id,
         "value" => public
       }}
    end
  end

  @doc false
  def token(service, access, id, value) do
    internal_id = internal_id(service, access, id)

    with {:ok, public} <- project(service, access, internal_id, value),
         {:ok, plaintext} <- open(service, access, internal_id, public, value["secret"]),
         true <- token?(plaintext) do
      {:ok, plaintext}
    else
      _ -> {:error, :storage_unavailable}
    end
  end

  defp existing_or_capacity(service, access, internal_id, request, now) do
    case current(service, access, internal_id, request, now) do
      {:ok, %{"value" => value}} ->
        with {:ok, public} <- project(service, access, internal_id, value),
             true <- same_binding?(public, request) do
          {:ok, public["created_at"]}
        else
          false -> {:error, :conflict}
          error -> error
        end

      {:error, :not_found} ->
        with {:ok, %{"items" => items}} <-
               list(service, access, request["expected_generation"], now),
             true <- length(items) < @maximum_endpoints do
          {:ok, now}
        else
          false -> {:error, :capacity_exceeded}
          error -> error
        end

      error ->
        error
    end
  end

  defp current(service, access, internal_id, request, now) do
    service.store
    |> Store.authorized_fetch(
      access,
      "admin",
      %{
        scope: access.scope,
        kind: "notification_endpoints",
        id: internal_id,
        generation: request["expected_generation"]
      },
      now
    )
    |> then(fn
      {:error, :invalid_cursor} -> {:error, :conflict}
      result -> result
    end)
  end

  defp project_items(service, access, items) do
    Enum.reduce_while(items, {:ok, []}, fn row, {:ok, projected} ->
      case project(service, access, row["id"], row["value"]) do
        {:ok, public} ->
          item = %{
            "id" => public["id"],
            "generation" => row["generation"],
            "value" => public
          }

          {:cont, {:ok, [item | projected]}}

        error ->
          {:halt, error}
      end
    end)
    |> then(fn
      {:ok, projected} -> {:ok, Enum.reverse(projected)}
      error -> error
    end)
  end

  defp project(service, access, internal_id, value) do
    with true <- exact?(value, @stored_fields),
         true <- value["owner"] == access.principal,
         true <- exact?(value["public"], @public_fields),
         public = value["public"],
         true <- public["schema"] == "wtr.notification-endpoint.v1",
         true <- Enum.all?([public["id"], public["app_id"]], &Codec.id?/1),
         true <- public["provider"] in @providers,
         true <- public["environment"] in @environments,
         true <- Codec.id?(public["revision"]),
         true <- Codec.time?(public["created_at"]) and Codec.time?(public["updated_at"]),
         true <- public["updated_at"] >= public["created_at"],
         true <- internal_id == internal_id(service, access, public["id"]),
         {:ok, token} <- open(service, access, internal_id, public, value["secret"]),
         true <- token?(token) do
      {:ok, public}
    else
      _ -> {:error, :storage_unavailable}
    end
  end

  defp update(service, access, operation, request, now, internal_id, value, action) do
    Update.new(%{
      principal: access.principal,
      scope: access.scope,
      authority: access,
      operation_id: operation,
      expected_generation: request["expected_generation"],
      now: now,
      request: %{
        "operation" =>
          if(action == "registered",
            do: "register_notification_endpoint",
            else: "unregister_notification_endpoint"
          ),
        "body" => request
      },
      observation: nil,
      publication: nil,
      response: %{"endpoint_id" => request["id"], "action" => action},
      records: [%{kind: "notification_endpoints", id: internal_id, value: value}],
      events: [
        %{
          "type" => "notification_endpoint.changed",
          "data" => %{
            "id" =>
              Projection.pseudonym(
                service.credentials,
                access.scope,
                "notification-endpoint-event",
                access.principal <> ":" <> request["id"]
              ),
            "action" => action
          }
        }
      ]
    })
  end

  defp same_binding?(public, request),
    do:
      public["provider"] == request["provider"] and public["app_id"] == request["app_id"] and
        public["environment"] == request["environment"]

  defp internal_id(service, access, id),
    do:
      Projection.pseudonym(
        service.credentials,
        access.scope,
        "notification-endpoint-record",
        access.principal <> ":" <> id
      )

  defp seal(service, access, internal_id, request) do
    key = Credentials.derive_key(service.credentials, :notification)
    nonce = :crypto.strong_rand_bytes(12)
    public_binding = Map.take(request, ~w(id provider app_id environment))

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        key,
        nonce,
        request["token"],
        aad(service, access, internal_id, public_binding),
        true
      )

    {:ok, "wtrn1." <> Base.url_encode64(nonce <> tag <> ciphertext, padding: false)}
  rescue
    _ -> {:error, :storage_unavailable}
  end

  defp open(service, access, internal_id, public, "wtrn1." <> encoded)
       when byte_size(encoded) in 1..8_192 do
    with {:ok, <<nonce::binary-size(12), tag::binary-size(16), ciphertext::binary>> = sealed} <-
           Base.url_decode64(encoded, padding: false),
         true <- Base.url_encode64(sealed, padding: false) == encoded,
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             Credentials.derive_key(service.credentials, :notification),
             nonce,
             ciphertext,
             aad(
               service,
               access,
               internal_id,
               Map.take(public, ~w(id provider app_id environment))
             ),
             tag,
             false
           ) do
      {:ok, plaintext}
    else
      _ -> {:error, :storage_unavailable}
    end
  end

  defp open(_, _, _, _, _), do: {:error, :storage_unavailable}

  defp aad(service, access, internal_id, binding),
    do:
      Codec.encode!(%{
        "schema" => "wtr.notification-secret.v1",
        "instance" => Credentials.instance_id(service.credentials),
        "scope" => access.scope,
        "owner" => access.principal,
        "record_id" => internal_id,
        "binding" => binding
      })

  defp token?(token) when is_binary(token) and byte_size(token) in 1..4_096 do
    String.valid?(token) and
      token
      |> :binary.bin_to_list()
      |> Enum.all?(&(&1 in 0x21..0x7E))
  end

  defp token?(_), do: false

  defp exact?(value, fields),
    do:
      is_map(value) and not is_struct(value) and
        Enum.sort(Map.keys(value)) == Enum.sort(fields)
end
