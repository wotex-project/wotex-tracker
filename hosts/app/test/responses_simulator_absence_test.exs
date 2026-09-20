defmodule Wotex.Tracker.Host.ResponsesSimulatorAbsenceTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Wotex.Tracker.Host.Config
  alias Wotex.Tracker.Service.{Codec, Credentials}

  test "the development Responses peer exists only in UI development builds" do
    directory =
      Path.expand("_build/test/responses-simulator-absence/#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)

    token = Credentials.generate_token()
    {:ok, digest} = Credentials.token_digest(token)

    {:ok, credentials} =
      Credentials.new(%{
        instance_id: "responses-simulator-absence",
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

    module = Wotex.Tracker.Host.Development.ResponsesHTTP

    if Code.ensure_loaded?(module) do
      assert {:ok, configured} = Config.load_browser(path, service)
      assert configured.prompt.http == module
    else
      assert {:error, :invalid_configuration} = Config.load_browser(path, service)
    end
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
