defmodule Wotex.Tracker.Service.HTTP.SSEParser do
  @moduledoc false
  alias Wotex.Binding.HTTP.SSE.Event

  # WHATWG event-stream framing. This local peer rejects malformed UTF-8 and
  # bounds frames (including ignored fields), lines, input chunks and batches.
  # Retry hints are metadata only; this client never reconnects automatically.
  def new(limit) when is_integer(limit) and limit > 0,
    do: %{
      limit: min(limit, 32_768),
      line: "",
      size: 0,
      lines: 0,
      data: [],
      event: "",
      id: "",
      retry: nil,
      first: true,
      skip_lf: false
    }

  def feed(state, bytes) when is_binary(bytes) and byte_size(bytes) <= 65_536,
    do: parse(bytes, state, [], 0)

  def feed(_, _), do: {:error, :invalid_sse}

  defp parse(<<>>, state, events, _), do: {:ok, state, Enum.reverse(events)}

  defp parse(<<10, rest::binary>>, %{skip_lf: true} = state, events, count),
    do: parse(rest, %{state | skip_lf: false}, events, count)

  defp parse(bytes, state, events, count) do
    state = %{state | skip_lf: false}

    case :binary.match(bytes, ["\r", "\n"]) do
      :nomatch ->
        if state.size + byte_size(bytes) <= state.limit,
          do:
            {:ok, %{state | line: state.line <> bytes, size: state.size + byte_size(bytes)},
             Enum.reverse(events)},
          else: {:error, :invalid_sse}

      {position, 1} ->
        prefix = binary_part(bytes, 0, position)
        ending = :binary.at(bytes, position)
        rest = binary_part(bytes, position + 1, byte_size(bytes) - position - 1)
        complete(prefix, ending, rest, state, events, count)
    end
  end

  defp complete(prefix, ending, rest, state, events, count) do
    line = state.line <> prefix
    size = state.size + byte_size(prefix) + if(ending == 13, do: 2, else: 1)

    if size <= state.limit and state.lines < 128 and String.valid?(line) do
      state = %{state | line: "", size: size, lines: state.lines + 1, skip_lf: ending == 13}
      {line, state} = bom(line, state)

      case line(line, state) do
        {:ok, state, nil} -> parse(rest, state, events, count)
        {:ok, state, event} when count < 32 -> parse(rest, state, [event | events], count + 1)
        _ -> {:error, :invalid_sse}
      end
    else
      {:error, :invalid_sse}
    end
  end

  defp bom(<<0xEF, 0xBB, 0xBF, rest::binary>>, %{first: true} = state),
    do: {rest, %{state | first: false}}

  defp bom(line, state), do: {line, %{state | first: false}}

  defp line("", %{data: []} = state), do: {:ok, reset(state), nil}

  defp line("", state) do
    data = state.data |> Enum.reverse() |> Enum.join("\n")
    event = if state.event == "", do: "message", else: state.event

    case Event.new(data, event: event, id: state.id, retry: state.retry) do
      {:ok, frame} -> {:ok, reset(state), frame}
      _ -> {:error, :invalid_sse}
    end
  end

  defp line(":" <> _, state), do: {:ok, state, nil}

  defp line(line, state) do
    case :binary.split(line, ":") do
      [name, " " <> value] -> field(name, value, state)
      [name, value] -> field(name, value, state)
      [name] -> field(name, "", state)
    end
  end

  defp field("data", value, state), do: {:ok, %{state | data: [value | state.data]}, nil}
  defp field("event", value, state), do: {:ok, %{state | event: value}, nil}

  defp field("id", value, state) do
    if :binary.match(value, <<0>>) == :nomatch,
      do: {:ok, %{state | id: value}, nil},
      else: {:ok, state, nil}
  end

  defp field("retry", value, state) do
    if byte_size(value) in 1..10 and Regex.match?(~r/\A[0-9]+\z/, value),
      do: {:ok, %{state | retry: String.to_integer(value)}, nil},
      else: {:ok, state, nil}
  end

  defp field(_, _, state), do: {:ok, state, nil}

  defp reset(state), do: %{state | size: 0, lines: 0, data: [], event: ""}
end
