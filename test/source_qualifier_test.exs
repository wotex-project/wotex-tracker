previous = System.get_env("WOTEX_TRACKER_SOURCE_QUALIFIER_NO_MAIN")
System.put_env("WOTEX_TRACKER_SOURCE_QUALIFIER_NO_MAIN", "1")
Code.require_file("../scripts/qualify_source.exs", __DIR__)

if previous do
  System.put_env("WOTEX_TRACKER_SOURCE_QUALIFIER_NO_MAIN", previous)
else
  System.delete_env("WOTEX_TRACKER_SOURCE_QUALIFIER_NO_MAIN")
end

defmodule Wotex.Tracker.SourceQualifierTest do
  use ExUnit.Case, async: true

  alias Wotex.Tracker.SourceQualifier

  setup do
    directory =
      Path.join(
        System.tmp_dir!(),
        "wtr-archive-evidence-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(directory)
    workspace = Path.join(directory, "workspace")
    destination = Path.join(directory, "evidence")
    File.mkdir!(workspace)
    File.mkdir!(destination)
    on_exit(fn -> File.rm_rf!(directory) end)
    {:ok, workspace: workspace, destination: destination}
  end

  test "qualification children cannot inherit host composition" do
    environment = %{
      "HOME" => "/private/home",
      "MIX_BUILD_PATH" => "/ambient/build",
      "MIX_BUILD_ROOT" => "/ambient/build-root",
      "MIX_DEPS_PATH" => "/ambient/deps",
      "MIX_LOCKFILE" => "/ambient/mix.lock",
      "MIX_ENV" => "test",
      "WOTEX_PATH_DEPS" => "1",
      "WOTEX_TRACKER_APNS_CONFIG" => "/private/apns.json",
      "WOTEX_TRACKER_CELLULAR_CONFIG" => "/private/cellular.json",
      "WOTEX_TRACKER_CONFIG" => "/private/service.json",
      "WOTEX_TRACKER_FUTURE_COMPOSITION" => "enabled",
      "WOTEX_TRACKER_UI" => "1",
      "WOTEX_TRACKER_UI_CONFIG" => "/private/browser.json"
    }

    qualified = SourceQualifier.clean_environment(environment)

    assert qualified["HOME"] == "/private/home"
    assert qualified["MIX_ENV"] == "prod"

    for key <- [
          "MIX_BUILD_PATH",
          "MIX_BUILD_ROOT",
          "MIX_DEPS_PATH",
          "MIX_LOCKFILE",
          "WOTEX_PATH_DEPS",
          "WOTEX_TRACKER_APNS_CONFIG",
          "WOTEX_TRACKER_CELLULAR_CONFIG",
          "WOTEX_TRACKER_CONFIG",
          "WOTEX_TRACKER_FUTURE_COMPOSITION",
          "WOTEX_TRACKER_UI",
          "WOTEX_TRACKER_UI_CONFIG"
        ] do
      assert Map.fetch!(qualified, key) == nil
    end
  end

  test "package discovery includes published documents and excludes local task notes", context do
    published = ~w(docs/guides/example.md docs/specs/catalogue.yaml)
    excluded = ~w(docs/tasks/local/example/notes.md docs/unpublished/example.md)

    for name <- published ++ excluded do
      path = Path.join(context.workspace, name)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "fixture")
    end

    names =
      Mix.Project.config()[:package][:files]
      |> Enum.flat_map(fn pattern ->
        Path.wildcard(Path.join(context.workspace, "#{pattern}/**/*"), match_dot: true)
      end)
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.relative_to(&1, context.workspace))

    for name <- published, do: assert(name in names)
    for name <- excluded, do: refute(name in names)
  end

  test "exact archives and member source hashes survive workspace cleanup", context do
    {archive, checksum} = fixture_archive(context.workspace, [{"lib/wotex.ex", "fixture source"}])
    archive_bytes = File.read!(archive)
    evidence = SourceQualifier.retain_archives!(context.workspace, context.destination)
    entry = evidence["wotex-0.1.0.tar"]
    member = entry["regular_members"]["lib/wotex.ex"]

    assert entry["result"] == "pass"
    assert entry["archive_sha256"] == digest(archive_bytes)
    assert entry["hex_inner_checksum"] == checksum
    refute entry["archive_sha256"] == entry["hex_inner_checksum"]

    assert Enum.sort(Map.keys(entry["outer_members"])) ==
             ~w(CHECKSUM VERSION contents.tar.gz metadata.config)

    assert member["source_matches"]
    assert member["sha256"] == digest("fixture source")
    assert member["source_sha256"] == member["sha256"]
    assert member["bytes"] == byte_size("fixture source")

    File.rm_rf!(context.workspace)
    retained = Path.join(context.destination, "archives/wotex-0.1.0.tar")
    assert File.read!(retained) == archive_bytes
    assert File.exists?(Path.join(context.destination, "archive-evidence.json"))
  end

  test "source drift fails inspection while retaining archive and mismatch evidence", context do
    {archive, _} = fixture_archive(context.workspace, [{"lib/wotex.ex", "archive source"}])
    source = Path.join(context.workspace, "wotex/packages/wotex/lib/wotex.ex")
    File.write!(source, "changed source")

    assert_raise RuntimeError, ~r/retained archive inspection failed/, fn ->
      SourceQualifier.retain_archives!(context.workspace, context.destination)
    end

    evidence =
      context.destination |> Path.join("archive-evidence.json") |> File.read!() |> Jason.decode!()

    entry = evidence["wotex-0.1.0.tar"]
    member = entry["regular_members"]["lib/wotex.ex"]
    assert entry["result"] == "failed"
    refute member["source_matches"]
    assert member["source_sha256"] == digest("changed source")
    assert member["sha256"] == digest("archive source")

    assert File.read!(Path.join(context.destination, "archives/wotex-0.1.0.tar")) ==
             File.read!(archive)
  end

  test "consumer failure keeps inspected archives without persisting exception secrets",
       context do
    fixture_archive(context.workspace, [{"lib/wotex.ex", "fixture source"}])
    SourceQualifier.retain_archives!(context.workspace, context.destination)
    receipt = File.read!(Path.join(context.destination, "archive-evidence.json"))
    error = RuntimeError.exception("fixture credential must never enter the receipt")
    SourceQualifier.retain_failure(context.workspace, context.destination, error)
    File.rm_rf!(context.workspace)

    assert File.read!(Path.join(context.destination, "archive-evidence.json")) == receipt
    failure = File.read!(Path.join(context.destination, "failure.json"))
    assert Jason.decode!(failure) == %{"result" => "failed", "failure_class" => "RuntimeError"}
    refute failure =~ "fixture credential"
    assert File.exists?(Path.join(context.destination, "archives/wotex-0.1.0.tar"))
    refute File.exists?(Path.join(context.destination, "source-consumer.json"))
  end

  test "source permission drift fails even when archive bytes match", context do
    fixture_archive(context.workspace, [{"lib/wotex.ex", "fixture source"}])
    source = Path.join(context.workspace, "wotex/packages/wotex/lib/wotex.ex")
    File.chmod!(source, 0o755)

    assert_raise RuntimeError, ~r/retained archive inspection failed/, fn ->
      SourceQualifier.retain_archives!(context.workspace, context.destination)
    end

    evidence =
      context.destination |> Path.join("archive-evidence.json") |> File.read!() |> Jason.decode!()

    member = evidence["wotex-0.1.0.tar"]["regular_members"]["lib/wotex.ex"]
    assert member["sha256"] == member["source_sha256"]
    assert member["source_mode"] == 0o755
    refute member["source_matches"]
  end

  test "unsafe archive members fail inspection without being extracted", context do
    outside = Path.join(context.workspace, "wotex/packages/outside.ex")
    File.mkdir_p!(Path.dirname(outside))
    File.write!(outside, "unsafe")
    fixture_archive(context.workspace, [{"../outside.ex", "unsafe"}], [])

    assert_raise RuntimeError, ~r/retained archive inspection failed/, fn ->
      SourceQualifier.retain_archives!(context.workspace, context.destination)
    end

    refute File.exists?(Path.join(context.destination, "outside.ex"))
    assert File.read!(outside) == "unsafe"
    assert File.exists?(Path.join(context.destination, "archives/wotex-0.1.0.tar"))
  end

  defp fixture_archive(workspace, files, sources \\ nil) do
    for {name, bytes} <- sources || files do
      path = Path.join(workspace, "wotex/packages/wotex/#{name}")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, bytes)
    end

    contents = Path.join(workspace, "fixture-contents.tar")
    entries = Enum.map(files, fn {name, bytes} -> {String.to_charlist(name), bytes} end)
    :ok = :erl_tar.create(String.to_charlist(contents), entries, [])
    compressed = contents |> File.read!() |> :zlib.gzip()
    checksum = digest(["3", "fixture metadata", compressed])
    archive = Path.join(workspace, "registry/tarballs/wotex-0.1.0.tar")
    File.mkdir_p!(Path.dirname(archive))

    :ok =
      :erl_tar.create(
        String.to_charlist(archive),
        [
          {~c"VERSION", "3"},
          {~c"CHECKSUM", checksum},
          {~c"metadata.config", "fixture metadata"},
          {~c"contents.tar.gz", compressed}
        ],
        []
      )

    {archive, checksum}
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
