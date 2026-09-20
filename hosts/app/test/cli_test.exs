defmodule Wotex.Tracker.Host.CLITest do
  @moduledoc false
  use ExUnit.Case, async: false
  alias Wotex.Tracker.Host.{Application, Config}
  alias Wotex.Tracker.Service.Codec
  alias Wotex.Tracker.Service.HTTP.Server

  test "the provisioned host and independent CLI execute the complete available machine workflow" do
    directory = Path.expand("_build/test/cli/#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.dirname(directory))
    previous = System.get_env("WOTEX_TRACKER_CONFIG")

    on_exit(fn ->
      if previous,
        do: System.put_env("WOTEX_TRACKER_CONFIG", previous),
        else: System.delete_env("WOTEX_TRACKER_CONFIG")

      File.rm_rf!(directory)
    end)

    cli = Path.expand("bin/trackerctl")

    init_args = [
      "--scope",
      "workshop",
      "init",
      "--directory",
      directory,
      "--instance-id",
      "cli-host",
      "--bind",
      "127.0.0.1",
      "--port",
      "43210"
    ]

    {output, 0} = System.cmd(cli, init_args, stderr_to_stdout: true)
    descriptor = Codec.decode!(output)
    token = File.read!(descriptor["token_file"]) |> String.trim()
    refute output =~ token
    {error, 1} = System.cmd(cli, init_args, stderr_to_stdout: true)
    assert error =~ "configuration_exists"
    assert File.read!(descriptor["token_file"]) |> String.trim() == token
    config_path = descriptor["config"]
    document = config_path |> File.read!() |> Codec.decode!()

    assert document["credentials"] |> hd() |> Map.fetch!("token_sha256") ==
             Base.encode16(:crypto.hash(:sha256, token), case: :lower)

    File.write!(config_path, Codec.encode!(put_in(document, ["listen", "port"], 0)))
    assert {:ok, _} = Config.load(config_path)
    System.put_env("WOTEX_TRACKER_CONFIG", config_path)
    {:ok, host} = Application.start(:normal, [])
    on_exit(fn -> if Process.alive?(host), do: Supervisor.stop(host) end)

    {Server, server, :supervisor, _} =
      List.keyfind(Supervisor.which_children(host), Server, 0)

    {:ok, {_, port}} = Server.listener_info(server)
    descriptor = Map.merge(descriptor, %{"url" => "http://127.0.0.1:#{port}", "cli" => cli})
    path = Path.join(directory, "client.json")
    File.write!(path, Codec.encode!(descriptor))
    File.chmod!(path, 0o600)

    elixir = System.find_executable("elixir") || flunk("Elixir executable is unavailable")

    code_paths =
      Enum.flat_map(:code.get_path(), fn code_path -> ["-pa", List.to_string(code_path)] end)

    {output, status} =
      System.cmd(elixir, code_paths ++ ["scripts/cli_consumer.exs", path], stderr_to_stdout: true)

    assert status == 0, output
    assert output =~ "CLI_CONSUMER_PASS"
    Supervisor.stop(host)
  end
end
