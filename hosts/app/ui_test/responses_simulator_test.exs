defmodule Wotex.Tracker.Host.Browser.ResponsesSimulatorTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Wotex.Tracker.Host.Browser.OpenAI
  alias Wotex.Tracker.Host.Development.ResponsesHTTP
  alias Wotex.Tracker.Host.{Config, PromptConfig}
  alias Wotex.Tracker.Service.{Codec, Credentials}

  test "private browser configuration selects only the fixed development peer" do
    directory =
      Path.expand("_build/test/responses-simulator/#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)

    token = Credentials.generate_token()
    {:ok, digest} = Credentials.token_digest(token)

    {:ok, credentials} =
      Credentials.new(%{
        instance_id: "responses-simulator",
        secret_key: :crypto.strong_rand_bytes(32),
        entries: [
          %{
            id: "developer",
            principal: "developer",
            token_sha256: digest,
            grants: %{"workshop" => ["read"]},
            expires_at: 9_007_199_254_740_991
          }
        ]
      })

    service = [
      directory: directory,
      credentials: credentials,
      ip: {127, 0, 0, 1},
      port: 0,
      public_origin: :listener,
      exposure: :loopback
    ]

    browser = %{
      "schema" => "wtr.browser.v1",
      "listen" => %{"ip" => "127.0.0.1", "port" => 4040},
      "exposure" => "loopback",
      "public_origin" => "http://127.0.0.1:4040",
      "secret_key_base" => String.duplicate("s", 64),
      "model" => model_document()
    }

    path = Path.join(directory, "browser.json")
    File.write!(path, Codec.encode!(browser))
    File.chmod!(path, 0o600)

    assert {:ok, configured} = Config.load_browser(path, service)
    assert configured.prompt.http == ResponsesHTTP
    refute inspect(configured.prompt) =~ model_document()["api_key"]

    for invalid <- [
          put_in(browser, ["model", "endpoint"], "https://other.invalid/v1/responses"),
          put_in(browser, ["model", "api_key"], "different-development-token"),
          put_in(browser, ["model", "provider"], "module-from-page")
        ] do
      File.write!(path, Codec.encode!(invalid))
      File.chmod!(path, 0o600)
      assert {:error, :invalid_configuration} = Config.load_browser(path, service)
    end
  end

  test "translates a bounded question through the complete Responses request path" do
    config = config()

    context = %{
      "question" => "temperature mean valid hour line",
      "utc_now" => "2026-09-20T20:00:00Z",
      "measurements" => [
        %{"kind" => "temperature", "unit" => "Cel"},
        %{"kind" => "humidity", "unit" => "%"}
      ],
      "aggregations" => ~w(last mean),
      "qualities" => ~w(suspect valid),
      "buckets" => ~w(day hour),
      "views" => ~w(line points)
    }

    assert {:ok, proposal} = OpenAI.request(config, context)

    assert proposal == %{
             "kind" => "query",
             "measurement" => "temperature",
             "aggregation" => "mean",
             "quality" => "valid",
             "from" => "2026-09-20T19:00:00Z",
             "to" => "2026-09-20T20:00:00Z",
             "bucket" => "hour",
             "view" => "line",
             "explanation" => "Deterministic development translation"
           }
  end

  test "returns a clarification for ambiguous choices and contains provider failure" do
    ambiguous = %{
      "question" => "show something",
      "utc_now" => "2026-09-20T20:00:00Z",
      "measurements" => [
        %{"kind" => "temperature", "unit" => "Cel"},
        %{"kind" => "humidity", "unit" => "%"}
      ],
      "aggregations" => ~w(last mean),
      "qualities" => ~w(suspect valid),
      "buckets" => ~w(day hour),
      "views" => ~w(line points)
    }

    assert {:ok,
            %{
              "kind" => "clarify",
              "question" => "Which measurement and display choices should I use?"
            }} = OpenAI.request(config(), ambiguous)

    unavailable = %{
      ambiguous
      | "question" => "simulate provider unavailable",
        "measurements" => [%{"kind" => "temperature", "unit" => "Cel"}],
        "aggregations" => ["mean"],
        "qualities" => ["valid"],
        "buckets" => ["hour"],
        "views" => ["line"]
    }

    assert {:error, %{"code" => "prompt_unavailable"}} =
             OpenAI.request(config(), unavailable)
  end

  test "the peer rejects widened authorities, headers and malformed requests" do
    config = config()

    context = %{
      "question" => "temperature",
      "utc_now" => "2026-09-20T20:00:00Z",
      "measurements" => [%{"kind" => "temperature", "unit" => "Cel"}],
      "aggregations" => ["mean"],
      "qualities" => ["valid"],
      "buckets" => ["hour"],
      "views" => ["line"]
    }

    assert ResponsesHTTP.simulator?()

    assert {:error, :invalid_configuration} =
             ResponsesHTTP.connect(:http, "responses-simulator.invalid", 80, [])

    assert {:error, :invalid_configuration} =
             ResponsesHTTP.connect(:https, "other.invalid", 443, mode: :passive)

    assert {:error, :invalid_configuration} =
             ResponsesHTTP.connect(:https, "responses-simulator.invalid", 443, mode: :active)

    assert {:ok, connection} =
             ResponsesHTTP.connect(:https, "responses-simulator.invalid", 443, mode: :passive)

    assert {:ok, body} = OpenAI.body(config, context)

    headers = [
      {"authorization", "Bearer development-responses-token"},
      {"content-type", "application/json"},
      {"accept", "application/json"}
    ]

    assert {:error, ^connection, :invalid_request} =
             ResponsesHTTP.request(connection, "GET", "/v1/responses", headers, body)

    assert {:error, ^connection, :invalid_request} =
             ResponsesHTTP.request(connection, "POST", "/v1/responses", [], body)

    assert {:error, ^connection, :invalid_request} =
             ResponsesHTTP.request(connection, "POST", "/v1/responses", headers, "{}")

    assert {:error, ^connection, :closed, []} = ResponsesHTTP.recv(connection, 0, 1_000)
    assert :ok = ResponsesHTTP.close(connection)
  end

  defp config do
    %PromptConfig{
      endpoint: "https://responses-simulator.invalid/v1/responses",
      model: "development-query-translator",
      api_key: "development-responses-token",
      timeout_ms: 1_000,
      max_request_bytes: 8_192,
      max_response_bytes: 8_192,
      max_output_tokens: 512,
      max_concurrent: 1,
      max_requests_per_minute: 10,
      max_cost_micro_usd: 100,
      input_price_micro_usd_per_million: 1,
      output_price_micro_usd_per_million: 1,
      http: ResponsesHTTP
    }
  end

  defp model_document do
    %{
      "provider" => "development_responses",
      "endpoint" => "https://responses-simulator.invalid/v1/responses",
      "model" => "development-query-translator",
      "api_key" => "development-responses-token",
      "disclosure" => "question_schema_utc",
      "timeout_ms" => 1_000,
      "max_request_bytes" => 8_192,
      "max_response_bytes" => 8_192,
      "max_output_tokens" => 512,
      "max_concurrent" => 1,
      "max_requests_per_minute" => 10,
      "max_cost_micro_usd" => 100,
      "input_price_micro_usd_per_million" => 1,
      "output_price_micro_usd_per_million" => 1
    }
  end
end
