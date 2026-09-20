defmodule Wotex.Tracker.Service.APNsAdapter do
  @moduledoc """
  Explicit token-authenticated Apple Push Notification service adapter.

  Configuration contains one P-256 provider signing key and a closed topic set.
  It is supplied directly by the host, never read from ambient files or
  application configuration, and its private key is excluded from inspection.
  Each call uses a bounded verified HTTP/2 TLS exchange and sends only a generic
  alert plus the opaque event reference.
  """

  @behaviour Wotex.Tracker.Service.NotificationAdapter

  alias Wotex.Tracker.Service.{
    APNsMintTransport,
    Codec,
    Identifier,
    NotificationTarget
  }

  @p256_oid {1, 2, 840, 10_045, 3, 1, 7}
  @invalid_token_reasons ~w(BadDeviceToken DeviceTokenNotForTopic Unregistered)
  @maximum_private_key_bytes 16_384
  @maximum_timeout 30_000
  @options ~w(team_id key_id private_key topics title body timeout_ms clock transport)a

  @derive {Inspect, only: [:team_id, :key_id, :topics, :title, :body, :timeout_ms]}
  @enforce_keys [
    :team_id,
    :key_id,
    :private_key,
    :topics,
    :title,
    :body,
    :timeout_ms,
    :clock,
    :transport,
    :transport_context
  ]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{}

  @doc "Admits one explicit APNs provider key, closed topic set and bounded transport."
  @spec new(keyword()) :: {:ok, t()} | {:error, :invalid_configuration}
  def new(options) do
    defaults = [
      title: "WotEx alert",
      body: "Open WotEx to review this alert.",
      timeout_ms: 5_000,
      clock: fn -> System.system_time(:millisecond) end,
      transport: {APNsMintTransport, nil}
    ]

    with true <- options?(options),
         values = defaults |> Keyword.merge(options) |> Map.new(),
         {:ok, key} <- private_key(values.private_key),
         true <- values?(values) do
      {transport, context} = values.transport

      {:ok,
       %__MODULE__{
         team_id: values.team_id,
         key_id: values.key_id,
         private_key: key,
         topics: values.topics,
         title: values.title,
         body: values.body,
         timeout_ms: values.timeout_ms,
         clock: values.clock,
         transport: transport,
         transport_context: context
       }}
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  @doc "Re-admits an opaque adapter configuration without exposing key material."
  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_configuration}
  def validate(%__MODULE__{} = config) do
    if config?(config), do: {:ok, config}, else: {:error, :invalid_configuration}
  end

  def validate(_), do: {:error, :invalid_configuration}

  @impl true
  def deliver(config, %NotificationTarget{} = target, payload) do
    reference = Identifier.uuid()

    with {:ok, config} <- validate(config),
         :ok <- target(config, target),
         {:ok, event_reference} <- payload(payload),
         {:ok, issued_at} <- issued_at(config.clock),
         {:ok, token} <- provider_token(config, issued_at),
         {:ok, body} <- notification(config, event_reference) do
      request = request(config, target, token, body, reference)

      config.transport
      |> call_transport(config.transport_context, request)
      |> classify(reference)
    else
      {:error, :invalid_target} -> {:rejected, reference}
      {:error, :invalid_payload} -> {:rejected, reference}
      _ -> {:retry, :unavailable}
    end
  rescue
    _ -> {:retry, :unavailable}
  catch
    _, _ -> {:retry, :unavailable}
  end

  def deliver(_, _, _), do: {:retry, :unavailable}

  defp request(config, target, provider_token, body, reference) do
    %{
      host: host(target.environment),
      path: "/3/device/" <> target.token,
      headers: [
        {"authorization", "bearer " <> provider_token},
        {"apns-id", reference},
        {"apns-topic", target.app_id},
        {"apns-push-type", "alert"},
        {"apns-priority", "10"},
        {"apns-expiration", "0"},
        {"content-type", "application/json"}
      ],
      body: body,
      timeout_ms: config.timeout_ms
    }
  end

  defp notification(config, reference) do
    Codec.encode(
      %{
        "aps" => %{
          "alert" => %{"title" => config.title, "body" => config.body},
          "thread-id" => "wotex-alerts"
        },
        "schema" => "wtr.notification-reference.v1",
        "event_ref" => reference
      },
      4_096
    )
  end

  defp provider_token(config, issued_at) do
    protected = encode(%{"alg" => "ES256", "kid" => config.key_id})
    claims = encode(%{"iss" => config.team_id, "iat" => issued_at})
    signing_input = protected <> "." <> claims

    with signature when is_binary(signature) <-
           :public_key.sign(signing_input, :sha256, config.private_key),
         {:ok, raw} <- raw_signature(signature) do
      {:ok, signing_input <> "." <> Base.url_encode64(raw, padding: false)}
    else
      _ -> {:error, :signing_failed}
    end
  rescue
    _ -> {:error, :signing_failed}
  catch
    _, _ -> {:error, :signing_failed}
  end

  defp raw_signature(signature) do
    case :public_key.der_decode(:"ECDSA-Sig-Value", signature) do
      {:"ECDSA-Sig-Value", r, s}
      when is_integer(r) and r >= 0 and is_integer(s) and s >= 0 ->
        {:ok, <<r::unsigned-big-size(256), s::unsigned-big-size(256)>>}

      _ ->
        {:error, :signing_failed}
    end
  rescue
    _ -> {:error, :signing_failed}
  end

  defp encode(value), do: value |> Codec.encode!() |> Base.url_encode64(padding: false)

  defp classify({:ok, 200, _headers, ""}, reference), do: {:accepted, reference}

  defp classify({:ok, status, _headers, body}, reference) when status in [400, 410] do
    case reason(body) do
      value when value in @invalid_token_reasons -> {:invalid_token, reference}
      _ when status == 400 -> {:rejected, reference}
      _ -> {:invalid_token, reference}
    end
  end

  defp classify({:ok, 429, _headers, _body}, _reference), do: {:retry, :rate_limited}

  defp classify({:ok, status, _headers, _body}, _reference) when status in 500..599,
    do: {:retry, :server_error}

  defp classify({:ok, status, _headers, _body}, reference) when status in 300..499,
    do: {:rejected, reference}

  defp classify({:error, :timeout}, _reference), do: {:retry, :timeout}
  defp classify({:error, _}, _reference), do: {:retry, :unavailable}
  defp classify(_, _reference), do: {:retry, :unavailable}

  defp reason(body) when is_binary(body) and byte_size(body) in 1..4_096 do
    case Codec.decode(body) do
      {:ok, %{"reason" => reason} = value}
      when is_binary(reason) and map_size(value) in 1..2 ->
        reason

      _ ->
        nil
    end
  end

  defp reason(_), do: nil

  defp call_transport(transport, context, request) do
    transport.request(context, request)
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp target(config, target) do
    allowed =
      target.provider == "apns" and target.app_id in config.topics and
        target.environment in ["sandbox", "production"] and device_token?(target.token)

    if allowed, do: :ok, else: {:error, :invalid_target}
  end

  defp payload(%{"schema" => "wtr.notification-reference.v1", "event_ref" => reference} = value)
       when map_size(value) == 2 do
    if Codec.id?(reference), do: {:ok, reference}, else: {:error, :invalid_payload}
  end

  defp payload(_), do: {:error, :invalid_payload}

  defp issued_at(clock) do
    case clock.() do
      milliseconds when is_integer(milliseconds) and milliseconds in 0..9_007_199_254_740_991 ->
        {:ok, div(milliseconds, 1_000)}

      _ ->
        {:error, :invalid_clock}
    end
  end

  defp host("sandbox"), do: "api.sandbox.push.apple.com"
  defp host("production"), do: "api.push.apple.com"

  defp options?(options) do
    Keyword.keyword?(options) and length(options) == length(Enum.uniq(Keyword.keys(options))) and
      Enum.all?(Keyword.keys(options), &(&1 in @options)) and
      Enum.all?([:team_id, :key_id, :private_key, :topics], &Keyword.has_key?(options, &1))
  end

  defp values?(values) do
    provider_id?(values.team_id) and provider_id?(values.key_id) and topics?(values.topics) and
      text?(values.title, 128) and text?(values.body, 512) and
      is_integer(values.timeout_ms) and values.timeout_ms in 1..@maximum_timeout and
      is_function(values.clock, 0) and transport?(values.transport)
  end

  defp config?(config) do
    provider_id?(config.team_id) and provider_id?(config.key_id) and topics?(config.topics) and
      private_config?(config)
  end

  defp private_config?(config),
    do:
      private_key?(config.private_key) and text?(config.title, 128) and text?(config.body, 512) and
        is_integer(config.timeout_ms) and config.timeout_ms in 1..@maximum_timeout and
        is_function(config.clock, 0) and transport?({config.transport, config.transport_context})

  defp private_key(pem)
       when is_binary(pem) and byte_size(pem) in 1..@maximum_private_key_bytes do
    with [entry] <- :public_key.pem_decode(pem),
         key <- :public_key.pem_entry_decode(entry),
         true <- private_key?(key) do
      {:ok, key}
    else
      _ -> {:error, :invalid_private_key}
    end
  rescue
    _ -> {:error, :invalid_private_key}
  catch
    _, _ -> {:error, :invalid_private_key}
  end

  defp private_key?({:ECPrivateKey, version, secret, {:namedCurve, @p256_oid}, public, _}) do
    version in [1, :ecPrivkeyVer1] and is_binary(secret) and byte_size(secret) == 32 and
      is_binary(public) and byte_size(public) == 65
  end

  defp private_key?(_), do: false

  defp provider_id?(value) when is_binary(value) and byte_size(value) == 10,
    do: value =~ ~r/\A[A-Z0-9]{10}\z/

  defp provider_id?(_), do: false

  defp topics?(topics),
    do:
      is_list(topics) and topics != [] and length(topics) <= 16 and
        topics == Enum.sort(Enum.uniq(topics)) and Enum.all?(topics, &topic?/1)

  defp topic?(topic) when is_binary(topic) and byte_size(topic) in 1..255,
    do:
      topic =~ ~r/\A[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\z/ and
        not String.contains?(topic, "..")

  defp topic?(_), do: false

  defp text?(value, maximum)
       when is_binary(value) and byte_size(value) >= 1 and byte_size(value) <= maximum,
       do: String.valid?(value) and not String.contains?(value, ["\r", "\n", <<0>>])

  defp text?(_, _), do: false

  defp transport?({module, _context}) when is_atom(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :request, 2)

  defp transport?(_), do: false

  defp device_token?(token) when is_binary(token) and byte_size(token) in 1..4_096,
    do: token =~ ~r/\A[0-9A-Fa-f]+\z/

  defp device_token?(_), do: false
end
