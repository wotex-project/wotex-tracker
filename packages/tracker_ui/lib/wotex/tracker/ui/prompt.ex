defmodule Wotex.Tracker.UI.Prompt do
  @moduledoc """
  Optional question translator boundary. The adapter sees only the question,
  permitted measurement names/units, closed choices and current UTC time.
  It never receives a service credential, asset identifier or reading.
  Its answer is untrusted and can only fill the structured query form.
  """

  @query_keys ~w(kind measurement aggregation quality from to bucket view explanation)
  @clarify_keys ~w(kind question)
  @aggregations ~w(count min max mean last)
  @qualities ~w(valid suspect valid_suspect)
  @buckets ~w(hour six_hours day)
  @views ~w(line area points)

  @doc "Returns whether this host explicitly installed a prompt adapter."
  def configured?(socket), do: match?({module, _} when is_atom(module), adapter(socket))

  @doc "Translates one bounded question; no service query is executed here."
  def propose(socket, question, measurements, now_ms)
      when is_binary(question) and is_list(measurements) and is_integer(now_ms) do
    with true <- String.valid?(question) and byte_size(question) in 1..512,
         question <- String.trim(question),
         true <- question != "",
         {module, context} when is_atom(module) <- adapter(socket),
         true <- function_exported?(module, :propose, 2),
         {:ok, now} <- DateTime.from_unix(now_ms, :millisecond),
         {:ok, proposal} <-
           call(module, context, %{
             "question" => question,
             "utc_now" => DateTime.to_iso8601(now),
             "measurements" => Enum.map(measurements, &Map.take(&1, ["kind", "unit"])),
             "aggregations" => @aggregations,
             "qualities" => @qualities,
             "buckets" => @buckets,
             "views" => @views
           }) do
      validate(proposal, measurements)
    else
      false -> {:error, %{"code" => "invalid_request"}}
      nil -> {:error, %{"code" => "prompt_unavailable"}}
      {:error, %{"code" => _} = error} -> {:error, error}
      _ -> {:error, %{"code" => "prompt_unavailable"}}
    end
  end

  def propose(_, _, _, _), do: {:error, %{"code" => "invalid_request"}}

  defp adapter(socket), do: socket.endpoint.config(:tracker_ui)[:prompt]

  defp call(module, context, request) do
    module.propose(context, request)
  rescue
    _ -> {:error, %{"code" => "prompt_unavailable"}}
  catch
    _, _ -> {:error, %{"code" => "prompt_unavailable"}}
  end

  defp validate(%{"kind" => "clarify", "question" => question} = proposal, _)
       when is_binary(question) and byte_size(question) in 1..256 do
    if Enum.sort(Map.keys(proposal)) == Enum.sort(@clarify_keys) and String.valid?(question),
      do: {:clarify, question},
      else: {:error, %{"code" => "prompt_invalid"}}
  end

  defp validate(%{"kind" => "query"} = proposal, measurements) do
    with true <- Enum.sort(Map.keys(proposal)) == Enum.sort(@query_keys),
         %{
           "measurement" => measurement,
           "aggregation" => aggregation,
           "quality" => quality,
           "from" => from,
           "to" => to,
           "bucket" => bucket,
           "view" => view,
           "explanation" => explanation
         } <- proposal,
         true <- valid_measurement?(measurement, measurements),
         true <- valid_choices?(aggregation, quality, bucket, view),
         true <- bounded?(from, 40) and bounded?(to, 40),
         true <- bounded?(explanation, 512) and explanation != "" do
      {:query, Map.take(proposal, ~w(measurement aggregation quality from to bucket view)),
       explanation}
    else
      _ -> {:error, %{"code" => "prompt_invalid"}}
    end
  end

  defp validate(_, _), do: {:error, %{"code" => "prompt_invalid"}}

  defp valid_measurement?(measurement, measurements),
    do: is_binary(measurement) and Enum.any?(measurements, &(&1["kind"] == measurement))

  defp valid_choices?(aggregation, quality, bucket, view),
    do:
      aggregation in @aggregations and quality in @qualities and
        bucket in @buckets and view in @views

  defp bounded?(value, max),
    do: is_binary(value) and String.valid?(value) and byte_size(value) <= max
end
