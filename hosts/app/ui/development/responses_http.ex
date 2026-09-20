defmodule Wotex.Tracker.Host.Development.ResponsesHTTP do
  @moduledoc """
  Deterministic dev/test peer for the configured Responses protocol boundary.

  The module implements the small Mint HTTP surface consumed by `OpenAI`. It
  admits the exact loopback-free simulator authority, bearer value and closed
  Responses request, then returns a completed structured-output envelope. No
  prompt, credential or proposal is persisted, and the module is absent from
  headless and production builds.
  """

  @host "responses-simulator.invalid"
  @path "/v1/responses"
  @token "development-responses-token"
  @request_keys ~w(input instructions max_output_tokens model store text tools)
  @proposal_fields ~w(kind measurement aggregation quality from to bucket view explanation question)

  @doc false
  @spec simulator?() :: true
  def simulator?, do: true

  @doc false
  def connect(:https, @host, 443, options) when is_list(options) do
    if Keyword.get(options, :mode) == :passive do
      {:ok, %{ref: nil, response: nil, status: nil, delivered: false}}
    else
      {:error, :invalid_configuration}
    end
  end

  def connect(_, _, _, _), do: {:error, :invalid_configuration}

  @doc false
  def request(conn, "POST", @path, headers, body) when is_map(conn) and is_binary(body) do
    with true <- headers?(headers),
         {:ok, status, response} <- response(body) do
      ref = make_ref()
      {:ok, %{conn | ref: ref, response: response, status: status}, ref}
    else
      _ -> {:error, conn, :invalid_request}
    end
  end

  def request(conn, _, _, _, _), do: {:error, conn, :invalid_request}

  @doc false
  def recv(%{delivered: false, ref: ref, response: response, status: status} = conn, 0, timeout)
      when is_reference(ref) and is_binary(response) and status in 100..599 and timeout > 0 do
    {:ok, %{conn | delivered: true},
     [{:status, ref, status}, {:data, ref, response}, {:done, ref}]}
  end

  def recv(conn, _, _), do: {:error, conn, :closed, []}

  @doc false
  def close(_), do: :ok

  defp response(body) do
    with {:ok, document} <- Jason.decode(body),
         true <- Enum.sort(Map.keys(document)) == Enum.sort(@request_keys),
         true <- is_binary(document["model"]) and document["model"] != "",
         true <- is_binary(document["instructions"]),
         true <- document["store"] == false and document["tools"] == [],
         true <- is_integer(document["max_output_tokens"]),
         true <- format?(document["text"]),
         {:ok, context} <- Jason.decode(document["input"]),
         {:ok, proposal} <- proposal(context) do
      status = if context["question"] == "simulate provider unavailable", do: 503, else: 200
      {:ok, status, envelope(proposal)}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp format?(
         %{
           "format" => %{
             "type" => "json_schema",
             "name" => "tracker_graph_query",
             "strict" => true,
             "schema" => schema
           }
         } = text
       ) do
    map_size(text) == 1 and is_map(schema) and schema["additionalProperties"] == false and
      Enum.sort(schema["required"]) == Enum.sort(@proposal_fields)
  end

  defp format?(_), do: false

  defp proposal(
         %{
           "question" => question,
           "utc_now" => utc_now,
           "measurements" => measurements,
           "aggregations" => aggregations,
           "qualities" => qualities,
           "buckets" => buckets,
           "views" => views
         } = context
       )
       when map_size(context) == 7 and is_binary(question) and is_binary(utc_now) and
              is_list(measurements) and is_list(aggregations) and is_list(qualities) and
              is_list(buckets) and is_list(views) do
    with {:ok, now, 0} <- DateTime.from_iso8601(utc_now),
         {:ok, measurement} <- measurement(question, measurements),
         {:ok, aggregation} <- choice(question, aggregations),
         {:ok, quality} <- choice(question, qualities),
         {:ok, bucket} <- choice(question, buckets),
         {:ok, view} <- choice(question, views) do
      {:ok,
       %{
         "kind" => "query",
         "measurement" => measurement,
         "aggregation" => aggregation,
         "quality" => quality,
         "from" => now |> DateTime.add(-3_600, :second) |> DateTime.to_iso8601(),
         "to" => DateTime.to_iso8601(now),
         "bucket" => bucket,
         "view" => view,
         "explanation" => "Deterministic development translation",
         "question" => ""
       }}
    else
      _ -> {:ok, clarification()}
    end
  end

  defp proposal(_), do: {:error, :invalid_context}

  defp measurement(question, measurements) do
    kinds =
      for %{"kind" => kind, "unit" => unit} <- measurements,
          is_binary(kind) and is_binary(unit),
          do: kind

    choose(question, kinds)
  end

  defp choice(question, values) when is_list(values), do: choose(question, values)

  defp choose(question, values) do
    lowered = String.downcase(question)
    matches = Enum.filter(values, &String.contains?(lowered, String.downcase(&1)))

    case {matches, values} do
      {[value], _} -> {:ok, value}
      {[], [value]} -> {:ok, value}
      _ -> {:error, :ambiguous}
    end
  end

  defp clarification do
    Map.new(@proposal_fields, fn
      "kind" -> {"kind", "clarify"}
      "question" -> {"question", "Which measurement and display choices should I use?"}
      field -> {field, ""}
    end)
  end

  defp envelope(proposal) do
    Jason.encode!(%{
      "status" => "completed",
      "output" => [
        %{
          "type" => "message",
          "content" => [%{"type" => "output_text", "text" => Jason.encode!(proposal)}]
        }
      ],
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
    })
  end

  defp headers?(headers) when is_list(headers) and length(headers) == 3 do
    Enum.sort(headers) ==
      Enum.sort([
        {"authorization", "Bearer " <> @token},
        {"content-type", "application/json"},
        {"accept", "application/json"}
      ])
  end

  defp headers?(_), do: false
end
