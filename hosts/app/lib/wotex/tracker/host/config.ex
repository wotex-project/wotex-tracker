defmodule Wotex.Tracker.Host.Config do
  @moduledoc """
  Loads private service and optional browser configuration for the standalone host.

  `load/1` delegates the closed service document to
  `Wotex.Tracker.Service.HTTP.FileConfig`. `load_browser/2` accepts a separate
  private browser file, checks its listener, origin, exposure, signing secret,
  optional model budgets and an optional bounded offline map pack against the service configuration, then returns
  a `Wotex.Tracker.Host.BrowserConfig`. An absent browser path leaves the
  headless service available; malformed configuration fails startup.
  """

  alias Wotex.Tracker.Host.{BrowserConfig, PromptConfig}
  alias Wotex.Tracker.Service.{APNsHostConfig, Cellular.HostConfig}
  alias Wotex.Tracker.Service.HTTP.Config, as: ServerConfig
  alias Wotex.Tracker.Service.HTTP.FileConfig
  import Wotex.Tracker.Service.HTTP.FileConfig, only: [listen: 1, exposure: 1, tls: 1]

  @doc "Loads validated service options from the shared private file format."
  @spec load(term()) :: {:ok, keyword()} | {:error, :invalid_configuration}
  defdelegate load(path), to: FileConfig

  @doc "Loads an optional private cellular listener configuration."
  @spec load_cellular(term(), keyword()) ::
          {:ok, HostConfig.t() | nil} | {:error, :invalid_configuration}
  def load_cellular(nil, _service_options), do: {:ok, nil}

  def load_cellular(path, service_options) when is_list(service_options) do
    with {:ok, document} <- FileConfig.read_document(path),
         credentials when not is_nil(credentials) <- service_options[:credentials],
         contract when not is_nil(contract) <- service_options[:contract] do
      HostConfig.new(document, credentials, contract)
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  def load_cellular(_, _), do: {:error, :invalid_configuration}

  @doc "Loads an optional private APNs provider and dispatcher configuration."
  @spec load_apns(term(), keyword()) ::
          {:ok, APNsHostConfig.t() | nil} | {:error, :invalid_configuration}
  def load_apns(nil, _service_options), do: {:ok, nil}

  def load_apns(path, service_options) when is_list(service_options) do
    with {:ok, document} <- FileConfig.read_document(path),
         {:ok, config} <- APNsHostConfig.new(document),
         dispatcher = APNsHostConfig.dispatcher_options(config),
         {:ok, _} <-
           ServerConfig.new(Keyword.put(service_options, :notification_dispatcher, dispatcher)) do
      {:ok, config}
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  def load_apns(_, _), do: {:error, :invalid_configuration}

  @doc "Loads an optional dev/test-only deterministic passive BLE simulator."
  @spec load_passive_simulator(term(), keyword()) ::
          {:ok, struct() | nil} | {:error, :invalid_configuration}
  def load_passive_simulator(nil, _service_options), do: {:ok, nil}

  def load_passive_simulator(path, service_options) when is_list(service_options) do
    module = Wotex.Tracker.Host.Development.PassiveSimulatorConfig

    if Code.ensure_loaded?(module) and function_exported?(module, :load, 2),
      do: module.load(path, service_options),
      else: {:error, :invalid_configuration}
  end

  def load_passive_simulator(_, _), do: {:error, :invalid_configuration}

  @doc "Loads an optional, separately private browser listener configuration."
  @spec load_browser(term(), keyword()) ::
          {:ok, BrowserConfig.t() | nil} | {:error, :invalid_configuration}
  def load_browser(nil, _), do: {:ok, nil}

  def load_browser(path, service_options) do
    with {:ok, document} <- FileConfig.read_document(path),
         %{
           "schema" => _schema,
           "listen" => listen,
           "exposure" => exposure,
           "public_origin" => origin,
           "secret_key_base" => secret
         } <- document,
         true <- browser_keys?(document),
         true <- is_binary(secret) and byte_size(secret) in 64..128,
         true <- is_binary(origin) and origin != "listener",
         {:ok, ip, port} <- listen(listen),
         true <- port in 1..65_535,
         {:ok, exposure} <- exposure(exposure),
         {:ok, tls} <- tls(document["tls"]),
         {:ok, prompt} <- prompt_config(document["model"]),
         {:ok, map_pack} <- map_pack(document),
         {:ok, config} <-
           ServerConfig.new(
             Keyword.merge(service_options,
               ip: ip,
               port: port,
               public_origin: origin,
               exposure: exposure,
               tls: tls
             )
           ),
         true <- browser_origin?(config) do
      {:ok,
       config
       |> Map.take([:ip, :port, :public_origin, :exposure, :tls])
       |> Map.put(:secret_key_base, secret)
       |> Map.put(:prompt, prompt)
       |> Map.put(:map_pack, map_pack)
       |> then(&struct!(BrowserConfig, &1))}
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  defp browser_origin?(%{exposure: :loopback} = config) do
    uri = URI.parse(config.public_origin)
    uri.port == config.port and uri.host in [to_string(:inet.ntoa(config.ip)), "localhost"]
  end

  defp browser_origin?(_), do: true

  defp browser_keys?(document) do
    base = ~w(schema listen exposure public_origin secret_key_base)
    keys = Map.keys(document)

    common? =
      Enum.all?(base, &(&1 in keys)) and
        Enum.all?(keys, &(&1 in (base ++ ~w(tls model map_pack))))

    case document["schema"] do
      "wtr.browser.v1" -> common? and not Map.has_key?(document, "map_pack")
      "wtr.browser.v2" -> common? and Map.has_key?(document, "map_pack")
      _ -> false
    end
  end

  defp map_pack(%{"schema" => "wtr.browser.v1"}), do: {:ok, nil}

  defp map_pack(%{"schema" => "wtr.browser.v2", "map_pack" => document}) do
    module = Wotex.Tracker.UI.MapPack

    if Code.ensure_loaded?(module),
      do: :erlang.apply(module, :new, [document]),
      else: {:error, :invalid_configuration}
  end

  defp map_pack(_), do: {:error, :invalid_configuration}

  defp prompt_config(nil), do: {:ok, nil}

  defp prompt_config(
         %{
           "provider" => "openai_responses",
           "endpoint" => endpoint,
           "model" => model,
           "api_key" => api_key,
           "disclosure" => "question_schema_utc",
           "timeout_ms" => timeout,
           "max_request_bytes" => request_bytes,
           "max_response_bytes" => response_bytes,
           "max_output_tokens" => output_tokens,
           "max_concurrent" => concurrent,
           "max_requests_per_minute" => per_minute,
           "max_cost_micro_usd" => cost,
           "input_price_micro_usd_per_million" => input_price,
           "output_price_micro_usd_per_million" => output_price
         } = config
       )
       when map_size(config) == 14 do
    limits = [
      {timeout, 1_000..10_000},
      {request_bytes, 1_024..8_192},
      {response_bytes, 1_024..32_768},
      {output_tokens, 128..2_048},
      {concurrent, 1..4},
      {per_minute, 1..60},
      {cost, 1..100_000},
      {input_price, 1..100_000_000},
      {output_price, 1..100_000_000}
    ]

    if prompt_endpoint?(endpoint) and prompt_token?(model, 1..100) and
         prompt_token?(api_key, 16..512) and
         Enum.all?(limits, fn {value, range} -> is_integer(value) and value in range end) do
      {:ok,
       %PromptConfig{
         endpoint: endpoint,
         model: model,
         api_key: api_key,
         timeout_ms: timeout,
         max_request_bytes: request_bytes,
         max_response_bytes: response_bytes,
         max_output_tokens: output_tokens,
         max_concurrent: concurrent,
         max_requests_per_minute: per_minute,
         max_cost_micro_usd: cost,
         input_price_micro_usd_per_million: input_price,
         output_price_micro_usd_per_million: output_price
       }}
    else
      {:error, :invalid_configuration}
    end
  end

  defp prompt_config(_), do: {:error, :invalid_configuration}

  defp prompt_endpoint?(endpoint) when is_binary(endpoint) do
    case URI.parse(endpoint) do
      %URI{
        scheme: "https",
        host: host,
        path: "/v1/responses",
        port: port,
        userinfo: nil,
        query: nil,
        fragment: nil
      } ->
        is_binary(host) and host != "" and port in [nil, 443]

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp prompt_endpoint?(_), do: false

  defp prompt_token?(value, range) when is_binary(value),
    do: byte_size(value) in range and Regex.match?(~r/\A[A-Za-z0-9._-]+\z/, value)

  defp prompt_token?(_, _), do: false
end
