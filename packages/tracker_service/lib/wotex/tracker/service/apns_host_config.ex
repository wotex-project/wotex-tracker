defmodule Wotex.Tracker.Service.APNsHostConfig do
  @moduledoc """
  Closed host configuration for one APNs notification dispatcher.

  The caller reads the private file and supplies its decoded document. This
  value admits the provider key, closed bundle-topic and scope sets, and finite
  delivery budgets without retaining the source path. Inspection excludes the
  provider key and notification text.
  """

  alias Wotex.Tracker.Service.{APNsAdapter, Codec}

  @fields ~w(schema team_id key_id private_key topics scopes title body provider_timeout_ms interval_ms retry_after_ms max_batch dispatch_timeout_ms)

  @derive {Inspect,
           only: [
             :topics,
             :scopes,
             :provider_timeout_ms,
             :interval_ms,
             :retry_after_ms,
             :max_batch,
             :dispatch_timeout_ms
           ]}
  @enforce_keys [
    :adapter,
    :topics,
    :scopes,
    :provider_timeout_ms,
    :interval_ms,
    :retry_after_ms,
    :max_batch,
    :dispatch_timeout_ms
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          adapter: APNsAdapter.t(),
          topics: [String.t()],
          scopes: [String.t()],
          provider_timeout_ms: pos_integer(),
          interval_ms: pos_integer(),
          retry_after_ms: pos_integer(),
          max_batch: pos_integer(),
          dispatch_timeout_ms: pos_integer()
        }

  @doc "Admits one exact private APNs host document."
  @spec new(term()) :: {:ok, t()} | {:error, :invalid_configuration}
  def new(%{"schema" => "wtr.apns-host.v1"} = document)
      when map_size(document) == length(@fields) do
    with true <- Enum.sort(Map.keys(document)) == Enum.sort(@fields),
         true <- scopes?(document["scopes"]),
         true <- integer?(document["provider_timeout_ms"], 1..30_000),
         true <- integer?(document["interval_ms"], 1..60_000),
         true <- integer?(document["retry_after_ms"], 1..86_400_000),
         true <- integer?(document["max_batch"], 1..32),
         true <- integer?(document["dispatch_timeout_ms"], 1..30_000),
         true <- document["dispatch_timeout_ms"] >= document["provider_timeout_ms"],
         {:ok, adapter} <-
           APNsAdapter.new(
             team_id: document["team_id"],
             key_id: document["key_id"],
             private_key: document["private_key"],
             topics: document["topics"],
             title: document["title"],
             body: document["body"],
             timeout_ms: document["provider_timeout_ms"]
           ) do
      {:ok,
       %__MODULE__{
         adapter: adapter,
         topics: document["topics"],
         scopes: document["scopes"],
         provider_timeout_ms: document["provider_timeout_ms"],
         interval_ms: document["interval_ms"],
         retry_after_ms: document["retry_after_ms"],
         max_batch: document["max_batch"],
         dispatch_timeout_ms: document["dispatch_timeout_ms"]
       }}
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  def new(_), do: {:error, :invalid_configuration}

  @doc "Returns the admitted dispatcher options without exposing the provider key."
  @spec dispatcher_options(t()) :: keyword()
  def dispatcher_options(%__MODULE__{} = config) do
    [
      adapter: {APNsAdapter, config.adapter},
      scopes: config.scopes,
      interval_ms: config.interval_ms,
      retry_after_ms: config.retry_after_ms,
      max_batch: config.max_batch,
      timeout_ms: config.dispatch_timeout_ms
    ]
  end

  defp scopes?(scopes),
    do:
      is_list(scopes) and scopes != [] and length(scopes) <= 64 and
        scopes == Enum.sort(Enum.uniq(scopes)) and Enum.all?(scopes, &Codec.id?/1)

  defp integer?(value, range), do: is_integer(value) and value in range
end
