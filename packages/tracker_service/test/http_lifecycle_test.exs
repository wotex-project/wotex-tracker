defmodule Wotex.Tracker.HTTPLifecycleTest do
  @moduledoc false
  use ExUnit.Case, async: false
  import Wotex.Tracker.Service.Fixtures
  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.HTTP.{Config, Server}

  setup do
    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)
    service()
  end

  test "configured TLS verifies a real certificate and serves an authenticated request",
       context do
    {cert, key, ca} = certificate(context.directory)

    options =
      Keyword.merge(options(context),
        exposure: :tls,
        public_origin: "https://localhost",
        tls: %{certfile: cert, keyfile: key}
      )

    server = start_supervised!({Server, options})
    {:ok, {_, port}} = Server.listener_info(server)
    url = String.to_charlist("https://localhost:#{port}/api/v1/scopes/workshop/capabilities")
    headers = [{~c"authorization", String.to_charlist("Bearer " <> context.admin)}]

    ssl = [
      verify: :verify_peer,
      cacertfile: String.to_charlist(ca),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    assert {:ok, {{_, 200, _}, _, body}} =
             :httpc.request(:get, {url, headers}, [timeout: 5000, ssl: ssl], body_format: :binary)

    assert body =~ ~s("import":"available")
    assert {:ok, config} = Config.new(options)
    assert {:ok, service} = Server.context(server, config)
    assert service.base_url == "https://localhost"

    assert {:ok, %{"schema" => "wtr.rule-schedule.v1", "scheduled" => 0}} =
             Server.rule_schedule(server)
  end

  test "shutdown closes an active stream and every owned process within the budget", context do
    server = start_supervised!(Supervisor.child_spec({Server, options(context)}, id: :server))
    {:ok, {_, port}} = Server.listener_info(server)

    {:ok, snapshot} =
      Service.list(context.service, context.admin, context.scope, "state", %{}, context.now)

    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 5000)

    :ok =
      :gen_tcp.send(socket, [
        "GET /api/v1/scopes/workshop/events/stream?cursor=",
        snapshot["stream_cursor"],
        " HTTP/1.1\r\nHost: localhost\r\nAccept: text/event-stream\r\nAuthorization: Bearer ",
        context.admin,
        "\r\n\r\n"
      ])

    receive_ready(socket, "")
    children = descendants(server)
    started = System.monotonic_time(:millisecond)
    stop_supervised!(:server)
    assert System.monotonic_time(:millisecond) - started < 10_000
    assert Enum.all?(children, &(not Process.alive?(&1)))
    closed(socket)
    assert {:error, :storage_unavailable} = Server.listener_info(server)
    assert {:error, :storage_unavailable} = Server.child(self(), :missing)
  end

  test "IPv6, explicit loopback origins and proxy exposure require complete bounded configuration",
       context do
    for change <- [
          [ip: {0, 0, 0, 0, 0, 0, 0, 1}],
          [public_origin: "http://127.0.0.1:43210/"],
          [exposure: :proxy, public_origin: "https://tracker.example.test"],
          [rule_scheduler: [max_rules: 32, refresh_interval: 100]]
        ] do
      assert {:ok, _} = Config.new(Keyword.merge(options(context), change))
    end

    for change <- [
          [ip: :any],
          [ip: {256, 0, 0, 1}],
          [ip: {0, 0, 0, 0, 0, 0, 0, 65_536}],
          [public_origin: "https://example.test/?secret=x"],
          [public_origin: nil],
          [
            exposure: :tls,
            public_origin: "https://example.test",
            tls: %{certfile: "relative", keyfile: "relative"}
          ],
          [exposure: :proxy, public_origin: "https://user:secret@example.test"],
          [rule_scheduler: [max_rules: 0]],
          [rule_scheduler: [unknown: true]]
        ] do
      assert {:error, :invalid_configuration} =
               Config.new(Keyword.merge(options(context), change))
    end

    assert {:error, :invalid_configuration} = Config.new(options(context) ++ [port: 0])
    assert {:error, :invalid_configuration} = Config.new([:not_a_keyword])
  end

  defp certificate(directory) do
    cert = Path.join(directory, "certificate.pem")
    key = Path.join(directory, "key.pem")
    ca = Path.join(directory, "ca.pem")
    ca_key = Path.join(directory, "ca-key.pem")
    csr = Path.join(directory, "request.csr")
    extensions = Path.join(directory, "extensions.conf")

    File.write!(
      extensions,
      "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost,IP:127.0.0.1\n"
    )

    commands = [
      [
        "req",
        "-x509",
        "-newkey",
        "rsa:2048",
        "-nodes",
        "-keyout",
        ca_key,
        "-out",
        ca,
        "-subj",
        "/CN=Fixture CA",
        "-days",
        "1",
        "-addext",
        "basicConstraints=critical,CA:TRUE",
        "-addext",
        "keyUsage=critical,keyCertSign,cRLSign"
      ],
      [
        "req",
        "-new",
        "-newkey",
        "rsa:2048",
        "-nodes",
        "-keyout",
        key,
        "-out",
        csr,
        "-subj",
        "/CN=localhost"
      ],
      [
        "x509",
        "-req",
        "-in",
        csr,
        "-CA",
        ca,
        "-CAkey",
        ca_key,
        "-CAcreateserial",
        "-out",
        cert,
        "-days",
        "1",
        "-extfile",
        extensions
      ]
    ]

    Enum.each(commands, fn args ->
      {_, 0} = System.cmd("openssl", args, stderr_to_stdout: true)
    end)

    File.chmod!(key, 0o600)
    File.chmod!(ca_key, 0o600)
    {cert, key, ca}
  end

  defp descendants(supervisor) do
    [
      supervisor
      | Enum.flat_map(Supervisor.which_children(supervisor), fn
          {_, pid, :supervisor, _} when is_pid(pid) -> descendants(pid)
          {_, pid, _, _} when is_pid(pid) -> [pid]
          _ -> []
        end)
    ]
  end

  defp receive_ready(socket, bytes) do
    assert byte_size(bytes) < 65_536

    unless String.contains?(bytes, "event: ready") do
      assert {:ok, more} = :gen_tcp.recv(socket, 0, 1000)
      receive_ready(socket, bytes <> more)
    end
  end

  defp closed(socket) do
    case :gen_tcp.recv(socket, 0, 1000) do
      {:ok, _} -> closed(socket)
      result -> assert result == {:error, :closed}
    end
  end

  defp options(context),
    do: [
      directory: context.directory,
      credentials: context.credentials,
      ip: {127, 0, 0, 1},
      port: 0,
      public_origin: :listener,
      exposure: :loopback,
      clock: fn -> context.now end,
      poll_interval: 25
    ]
end
