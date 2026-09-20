defmodule Wotex.Tracker.Service.HTTP.Config do
  @moduledoc false

  alias Wotex.Tracker.Service.{Codec, Credentials}

  @required ~w(directory credentials ip port public_origin exposure)a
  @optional ~w(tls clock request_timeout stream_lifetime poll_interval store_options operational_history rule_scheduler notification_dispatcher contract)a

  def new(options) when is_list(options) do
    if Keyword.keyword?(options) and length(options) == map_size(Map.new(options)),
      do: admit(Map.new(options)),
      else: {:error, :invalid_configuration}
  end

  def new(_), do: {:error, :invalid_configuration}

  defp admit(input) do
    value =
      Map.merge(
        %{
          tls: nil,
          clock: fn -> System.system_time(:millisecond) end,
          request_timeout: 5000,
          stream_lifetime: 300_000,
          poll_interval: 1000,
          store_options: [],
          operational_history: [],
          rule_scheduler: [],
          notification_dispatcher: nil,
          contract: :ruuvi_raw_v2
        },
        input
      )

    if Enum.all?(@required, &Map.has_key?(input, &1)) and
         Enum.all?(Map.keys(input), &(&1 in (@required ++ @optional))) and valid?(value),
       do: {:ok, value},
       else: {:error, :invalid_configuration}
  end

  defp valid?(value) do
    identity?(value) and contract?(value.contract) and options?(value) and
      budgets?(value) and exposure?(value)
  end

  defp contract?(contract),
    do: contract in [:ruuvi_raw_v2, :teltonika_tat140_codec8e]

  defp identity?(value),
    do:
      is_binary(value.directory) and match?({:ok, _}, Credentials.validate(value.credentials)) and
        address?(value.ip) and is_integer(value.port) and value.port in 0..65_535

  defp options?(value),
    do:
      is_function(value.clock, 0) and store_options?(value.store_options) and
        history_options?(value.operational_history) and
        scheduler_options?(value.rule_scheduler) and
        dispatcher_options?(value.notification_dispatcher)

  defp budgets?(value),
    do:
      budget?(value.request_timeout, 5000) and
        budget?(value.stream_lifetime, 300_000) and budget?(value.poll_interval, 1000)

  defp store_options?(options),
    do:
      is_list(options) and Keyword.keyword?(options) and
        length(options) == length(Enum.uniq(Keyword.keys(options))) and
        Enum.all?(
          Keyword.keys(options),
          &(&1 in ~w(max_rows max_pages busy_timeout timeout forward_max_items forward_max_bytes forward_max_age_ms forward_max_attempts domain_inactivity_retention_ms retention_check_ms)a)
        )

  defp history_options?(options),
    do:
      is_list(options) and Keyword.keyword?(options) and
        Enum.all?(Keyword.keys(options), &(&1 in [:max_samples, :retention_ms]))

  defp scheduler_options?(options),
    do:
      is_list(options) and Keyword.keyword?(options) and
        length(options) == length(Enum.uniq(Keyword.keys(options))) and
        Enum.all?(
          Keyword.keys(options),
          &(&1 in [:max_rules, :refresh_interval, :monotonic_clock])
        ) and is_integer(Keyword.get(options, :max_rules, 1_024)) and
        Keyword.get(options, :max_rules, 1_024) in 1..1_024 and
        is_integer(Keyword.get(options, :refresh_interval, 1_000)) and
        Keyword.get(options, :refresh_interval, 1_000) in 1..60_000 and
        is_function(
          Keyword.get(options, :monotonic_clock, fn -> System.monotonic_time(:millisecond) end),
          0
        )

  defp dispatcher_options?(nil), do: true

  defp dispatcher_options?(options) when is_list(options) do
    allowed = [:adapter, :scopes, :interval_ms, :retry_after_ms, :max_batch, :timeout_ms]

    Keyword.keyword?(options) and
      length(options) == length(Enum.uniq(Keyword.keys(options))) and
      Enum.all?(Keyword.keys(options), &(&1 in allowed)) and
      dispatcher_values?(options)
  end

  defp dispatcher_options?(_), do: false

  defp dispatcher_values?(options),
    do:
      Keyword.has_key?(options, :adapter) and adapter?(Keyword.get(options, :adapter)) and
        scopes?(Keyword.get(options, :scopes)) and
        option_integer?(options, :interval_ms, 1..60_000) and
        option_integer?(options, :retry_after_ms, 1..86_400_000) and
        option_integer?(options, :max_batch, 1..32) and
        option_integer?(options, :timeout_ms, 1..30_000)

  defp adapter?({module, _context}) when is_atom(module),
    do: function_exported?(module, :deliver, 3)

  defp adapter?(_), do: false

  defp scopes?(nil), do: true

  defp scopes?(scopes),
    do:
      is_list(scopes) and scopes != [] and length(scopes) <= 64 and
        scopes == Enum.sort(Enum.uniq(scopes)) and Enum.all?(scopes, &Codec.id?/1)

  defp option_integer?(options, key, range) do
    case Keyword.fetch(options, key) do
      :error -> true
      {:ok, value} -> is_integer(value) and value in range
    end
  end

  defp budget?(value, max), do: is_integer(value) and value in 1..max

  defp address?(ip) when is_tuple(ip) and tuple_size(ip) == 4,
    do: Enum.all?(Tuple.to_list(ip), &(is_integer(&1) and &1 in 0..255))

  defp address?(ip) when is_tuple(ip) and tuple_size(ip) == 8,
    do: Enum.all?(Tuple.to_list(ip), &(is_integer(&1) and &1 in 0..65_535))

  defp address?(_), do: false
  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_), do: false

  defp exposure?(%{exposure: :loopback, tls: nil, public_origin: :listener} = value),
    do: loopback?(value.ip)

  defp exposure?(%{exposure: :loopback, tls: nil} = value),
    do: loopback?(value.ip) and origin?(value.public_origin, "http")

  defp exposure?(%{exposure: :proxy, tls: nil} = value),
    do: origin?(value.public_origin, "https")

  defp exposure?(%{exposure: :tls, tls: %{certfile: cert, keyfile: key} = tls} = value),
    do:
      map_size(tls) == 2 and is_binary(cert) and is_binary(key) and
        Path.type(cert) == :absolute and Path.type(key) == :absolute and
        origin?(value.public_origin, "https")

  defp exposure?(_), do: false

  defp origin?(value, scheme) when is_binary(value) and byte_size(value) in 1..2048 do
    case URI.new(value) do
      {:ok,
       %URI{
         scheme: ^scheme,
         userinfo: nil,
         query: nil,
         fragment: nil,
         path: path,
         host: host,
         port: port
       }}
      when path in [nil, "", "/"] and is_binary(host) and host != "" and port in 1..65_535 ->
        true

      _ ->
        false
    end
  end

  defp origin?(_, _), do: false
end
