defmodule Wotex.Tracker.SSEParserTest do
  use ExUnit.Case, async: true
  alias Wotex.Binding.HTTP.SSE.Event
  alias Wotex.Tracker.Service.HTTP.SSEParser

  test "all byte splits preserve BOM, UTF-8, line endings, data joining and retained event ID" do
    bytes =
      <<0xEF, 0xBB, 0xBF>> <>
        ": ready\r\nid: opaque\revent: property\ndata: {\r\ndata:  \"x\":\"å\"}\nretry: 250\n\ndata: 0\r\r"

    {:ok, expected, frames} = SSEParser.feed(SSEParser.new(32_768), bytes)

    assert [
             %Event{data: "{\n \"x\":\"å\"}", event: "property", id: "opaque", retry: 250},
             %Event{data: "0", event: "message", id: "opaque", retry: 250}
           ] = frames

    for split <- 0..byte_size(bytes) do
      first = binary_part(bytes, 0, split)
      last = binary_part(bytes, split, byte_size(bytes) - split)
      {:ok, state, one} = SSEParser.feed(SSEParser.new(32_768), first)
      assert {:ok, ^expected, two} = SSEParser.feed(state, last)
      assert one ++ two == frames
    end

    {actual, parsed} =
      bytes
      |> :binary.bin_to_list()
      |> Enum.reduce({SSEParser.new(32_768), []}, fn byte, {state, frames} ->
        {:ok, state, next} = SSEParser.feed(state, <<byte>>)
        {state, frames ++ next}
      end)

    assert actual == expected
    assert parsed == frames
  end

  test "empty data, ignored fields, null ID, retry hints and incomplete EOF retain SSE semantics" do
    {:ok, state, frames} =
      SSEParser.feed(
        SSEParser.new(32_768),
        "id: stable\n\nid: bad\0id\ndata\nunknown: ignored\nretry: 2x\n\ndata: 1\nid\nevent\n\ndata: incomplete"
      )

    assert [
             %Event{data: "", id: "stable", retry: nil},
             %Event{data: "1", id: "", event: "message"}
           ] = frames

    assert {:ok, ^state, []} = SSEParser.feed(state, "")

    for retry <- ["", "-1", "1.0", "11111111111"] do
      assert {:ok, _, [%Event{retry: nil}]} =
               SSEParser.feed(SSEParser.new(32_768), "retry: " <> retry <> "\ndata: 1\n\n")
    end
  end

  test "all memory ceilings and malformed fields fail with bounded errors" do
    assert {:ok, _, [%Event{data: "1"}]} = SSEParser.feed(SSEParser.new(9), "data: 1\n\n")
    assert {:error, :invalid_sse} = SSEParser.feed(SSEParser.new(8), "data: 1\n\n")

    assert {:error, :invalid_sse} =
             SSEParser.feed(SSEParser.new(32_768), :binary.copy("x", 32_769))

    assert {:error, :invalid_sse} =
             SSEParser.feed(SSEParser.new(32_768), :binary.copy("\n", 65_537))

    assert {:error, :invalid_sse} =
             SSEParser.feed(SSEParser.new(32_768), :binary.copy(":\n", 129))

    assert {:error, :invalid_sse} =
             SSEParser.feed(SSEParser.new(32_768), :binary.copy("data: 1\n\n", 33))

    assert {:error, :invalid_sse} =
             SSEParser.feed(SSEParser.new(32_768), "data: " <> <<255>> <> "\n\n")

    assert {:error, :invalid_sse} =
             SSEParser.feed(SSEParser.new(32_768), "event: bad\0field\ndata: 1\n\n")
  end
end
