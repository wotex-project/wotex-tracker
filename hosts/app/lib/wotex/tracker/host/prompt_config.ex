defmodule Wotex.Tracker.Host.PromptConfig do
  @moduledoc "Validated host-owned model configuration; inspection omits the API key."
  @derive {Inspect,
           only: [
             :endpoint,
             :model,
             :timeout_ms,
             :max_request_bytes,
             :max_response_bytes,
             :max_output_tokens,
             :max_concurrent,
             :max_requests_per_minute,
             :max_cost_micro_usd
           ]}
  @enforce_keys [
    :endpoint,
    :model,
    :api_key,
    :timeout_ms,
    :max_request_bytes,
    :max_response_bytes,
    :max_output_tokens,
    :max_concurrent,
    :max_requests_per_minute,
    :max_cost_micro_usd,
    :input_price_micro_usd_per_million,
    :output_price_micro_usd_per_million
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          endpoint: String.t(),
          model: String.t(),
          api_key: String.t(),
          timeout_ms: pos_integer(),
          max_request_bytes: pos_integer(),
          max_response_bytes: pos_integer(),
          max_output_tokens: pos_integer(),
          max_concurrent: pos_integer(),
          max_requests_per_minute: pos_integer(),
          max_cost_micro_usd: pos_integer(),
          input_price_micro_usd_per_million: pos_integer(),
          output_price_micro_usd_per_million: pos_integer()
        }
end
