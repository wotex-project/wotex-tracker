defmodule Wotex.Tracker.CIWorkflowTest do
  use ExUnit.Case, async: true

  @workflow Path.expand("../.github/workflows/ci.yml", __DIR__) |> File.read!()
  @monorepo_revision "cd73c5493d3453ae9ecd203c63b589676c9b9fd6"

  test "CI checks out one exact WoTEx monorepo cohort per job" do
    assert occurrences(@workflow, "repository: wotex-project/wotex\n") == 2
    assert occurrences(@workflow, "ref: #{@monorepo_revision}\n") == 2
    assert occurrences(@workflow, "path: wotex\n") == 2

    refute @workflow =~ "repository: wotex-project/wotex-runtime"
    refute @workflow =~ "repository: wotex-project/wotex-binding-http"
  end

  test "development dependencies resolve inside the adjacent monorepo" do
    sources = [
      File.read!(Path.expand("../mix.exs", __DIR__)),
      File.read!(Path.expand("../packages/tracker_service/mix.exs", __DIR__)),
      File.read!(Path.expand("../packages/tracker_ui/mix.exs", __DIR__))
    ]

    assert Enum.all?(sources, &(&1 =~ "wotex/packages/"))
    refute Enum.any?(sources, &(&1 =~ "../wotex-runtime" or &1 =~ "../wotex-binding-http"))
  end

  defp occurrences(source, pattern), do: length(:binary.matches(source, pattern))
end
