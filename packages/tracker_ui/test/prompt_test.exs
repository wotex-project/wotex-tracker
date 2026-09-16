defmodule Wotex.Tracker.UI.PromptTest do
  @moduledoc false
  use ExUnit.Case, async: false
  alias Wotex.Tracker.UI.Prompt

  defmodule Endpoint do
    @moduledoc false
    def config(:tracker_ui), do: [prompt: {Wotex.Tracker.UI.PromptTest.Peer, nil}]
  end

  defmodule NoProvider do
    @moduledoc false
    def config(:tracker_ui), do: []
  end

  defmodule Peer do
    @moduledoc false
    def propose(_, _) do
      case Process.get(:prompt_reply) do
        :raise -> raise "provider failed"
        reply -> reply
      end
    end
  end

  @measurements [%{"kind" => "temperature", "unit" => "Cel", "value" => 24.3}]
  @proposal %{
    "kind" => "query",
    "measurement" => "temperature",
    "aggregation" => "mean",
    "quality" => "valid",
    "from" => "2023-11-14T00:00:00Z",
    "to" => "2023-11-15T00:00:00Z",
    "bucket" => "hour",
    "view" => "line",
    "explanation" => "Daily temperature mean"
  }

  test "question translation accepts only closed, bounded form fields" do
    socket = %{endpoint: Endpoint}
    assert Prompt.configured?(socket)
    Process.put(:prompt_reply, {:ok, @proposal})

    assert {:query, input, "Daily temperature mean"} =
             Prompt.propose(socket, "  Temperature today  ", @measurements, 1_700_000_000_000)

    assert input == Map.take(@proposal, ~w(measurement aggregation quality from to bucket view))

    for bad <- [
          Map.put(@proposal, "measurement", "other-asset"),
          Map.put(@proposal, "aggregation", "SQL"),
          Map.put(@proposal, "quality", "all"),
          Map.put(@proposal, "from", String.duplicate("1", 41)),
          Map.put(@proposal, "explanation", ""),
          Map.put(@proposal, "url", "https://bad.example"),
          %{"kind" => "clarify", "question" => "Which day?", "action" => "unlock"},
          %{"kind" => "clarify", "question" => String.duplicate("x", 257)}
        ] do
      Process.put(:prompt_reply, {:ok, bad})

      assert {:error, %{"code" => "prompt_invalid"}} =
               Prompt.propose(socket, "Temperature today", @measurements, 1_700_000_000_000)
    end
  end

  test "missing or failing provider and invalid input cannot interrupt structured analytics" do
    socket = %{endpoint: Endpoint}
    refute Prompt.configured?(%{endpoint: NoProvider})

    assert {:error, %{"code" => "prompt_unavailable"}} =
             Prompt.propose(%{endpoint: NoProvider}, "Question", @measurements, 1_700_000_000_000)

    for question <- ["", "  ", String.duplicate("q", 513), <<255>>] do
      assert {:error, %{"code" => "invalid_request"}} =
               Prompt.propose(socket, question, @measurements, 1_700_000_000_000)
    end

    Process.put(:prompt_reply, :raise)

    assert {:error, %{"code" => "prompt_unavailable"}} =
             Prompt.propose(socket, "Question", @measurements, 1_700_000_000_000)
  end
end
