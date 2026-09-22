defmodule Wotex.Tracker.Service.PassiveHostConfig do
  @moduledoc """
  Closed host configuration for one explicitly selected passive BLE adapter.

  The private document binds an existing ingest credential, scope, stable
  adapter identifier and finite polling budgets. The caller supplies the
  adapter module and its already-bounded context; configuration data cannot
  select or construct executable code. This keeps OS/radio ownership in the
  host while composing the common `PassiveIngress` and `PassiveScanner` owners.
  """

  alias Wotex.Tracker.Service.{Codec, Credentials, PassiveIngress, PassiveScanner}

  @derive {Inspect, only: [:adapter_id, :scope, :interval_ms, :timeout_ms]}
  @enforce_keys [:adapter_id, :scope, :interval_ms, :timeout_ms, :token, :adapter]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          adapter_id: String.t(),
          scope: String.t(),
          interval_ms: non_neg_integer(),
          timeout_ms: pos_integer(),
          token: String.t(),
          adapter: {module(), term()}
        }

  @doc "Admits one private scanner document and caller-selected adapter."
  @spec new(term(), term(), term()) :: {:ok, t() | nil} | {:error, :invalid_configuration}
  def new(nil, _credentials, _adapter), do: {:ok, nil}

  def new(
        %{
          "schema" => "wtr.passive-ble-host.v1",
          "adapter" => adapter_id,
          "token" => token,
          "scope" => scope,
          "interval_ms" => interval_ms,
          "timeout_ms" => timeout_ms
        } = document,
        credentials,
        {module, context}
      )
      when map_size(document) == 6 and is_atom(module) do
    with {:ok, _credentials} <- Credentials.validate(credentials),
         true <- Codec.id?(adapter_id) and Codec.id?(scope),
         true <- Credentials.configured?(credentials, token, scope, "ingest"),
         true <- adapter?(module),
         true <- is_integer(interval_ms) and interval_ms in 0..60_000,
         true <- is_integer(timeout_ms) and timeout_ms in 1..30_000 do
      {:ok,
       %__MODULE__{
         adapter_id: adapter_id,
         scope: scope,
         interval_ms: interval_ms,
         timeout_ms: timeout_ms,
         token: token,
         adapter: {module, context}
       }}
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  def new(_, _, _), do: {:error, :invalid_configuration}

  @doc false
  @spec child_specs(t(), term(), atom()) :: [{module(), keyword()}]
  def child_specs(%__MODULE__{} = config, service, ingress_name)
      when is_atom(ingress_name) do
    [
      {PassiveIngress,
       service: service,
       token: config.token,
       scope: config.scope,
       adapter: config.adapter_id,
       name: ingress_name},
      {PassiveScanner,
       adapter: config.adapter,
       ingress: ingress_name,
       interval_ms: config.interval_ms,
       timeout_ms: config.timeout_ms}
    ]
  end

  defp adapter?(module),
    do:
      Code.ensure_loaded?(module) and function_exported?(module, :init, 1) and
        function_exported?(module, :next, 1)
end
