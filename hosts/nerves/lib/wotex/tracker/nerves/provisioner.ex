defmodule Wotex.Tracker.Nerves.Provisioner do
  @moduledoc """
  Prepares a private, create-only service tree for installation on an appliance.

  The generated document always names `/root/tracker` as its runtime root. The
  destination may instead be an offline staging or mounted-media directory.
  Provisioning never emits the bearer token; it reports the private token file.
  """

  alias Wotex.Tracker.Nerves.{BrowserProvisioning, StoragePolicy, TLSProvisioning}
  alias Wotex.Tracker.Service.HostProvisioning

  @runtime_root "/root/tracker"
  @maximum_expiry_seconds 604_800

  @doc "Parses bounded provisioning arguments using the current Unix time."
  @spec run([String.t()]) :: {:ok, map()} | {:error, atom()}
  def run(arguments), do: run(arguments, System.system_time(:millisecond), @runtime_root)

  @doc false
  @spec run([String.t()], integer(), String.t()) :: {:ok, map()} | {:error, atom()}
  def run(["--" | arguments], now, runtime_root), do: run(arguments, now, runtime_root)

  def run(arguments, now, runtime_root) when is_list(arguments) and is_integer(now) do
    {options, rest, invalid} =
      OptionParser.parse(arguments,
        strict: [
          directory: :string,
          instance_id: :string,
          scope: :string,
          port: :integer,
          browser_port: :integer,
          listen_ip: :string,
          public_origin: :string,
          tls_cert: :string,
          tls_key: :string,
          expires_in: :integer
        ]
      )

    values = Map.new(options)
    expires_in = Map.get(values, :expires_in, 86_400)
    browser_port = values[:browser_port]

    with true <- invalid == [] and rest == [],
         directory when is_binary(directory) <- values[:directory],
         true <- Path.type(directory) == :absolute and Path.expand(directory) == directory,
         instance when is_binary(instance) <- values[:instance_id],
         scope when is_binary(scope) <- values[:scope],
         {:ok, tls} <- tls_options(values, runtime_root),
         port = Map.get(values, :port, if(tls, do: 443, else: 4000)),
         true <- expires_in in 1..@maximum_expiry_seconds,
         true <- port in 1..65_535,
         true <- is_nil(browser_port) or browser_port in 1..65_535,
         true <- is_nil(browser_port) or browser_port != port,
         {:ok, service} <-
           provision_service(
             directory,
             runtime_root,
             instance,
             scope,
             port,
             now + expires_in * 1_000,
             tls
           ),
         {:ok, marker} <- provision_storage(service, directory, runtime_root, instance),
         {:ok, browser} <- provision_browser(service, marker, directory, browser_port, scope) do
      paths = service.host

      result =
        %{
          "schema" => "wtr.nerves-provisioning.v1",
          "config_file" => paths.config,
          "storage_marker" => marker,
          "token_file" => paths.token_file,
          "staged_data_directory" => paths.data_directory,
          "runtime_config_file" => paths.runtime_config,
          "runtime_data_directory" => paths.runtime_data_directory
        }
        |> add_tls_result(service.tls)

      {:ok, if(browser, do: Map.put(result, "browser_config_file", browser), else: result)}
    else
      false -> {:error, :invalid_arguments}
      nil -> {:error, :invalid_arguments}
      {:error, _} = error -> error
      _ -> {:error, :invalid_arguments}
    end
  end

  def run(_, _, _), do: {:error, :invalid_arguments}

  defp tls_options(values, runtime_root) do
    options = [values[:listen_ip], values[:public_origin], values[:tls_cert], values[:tls_key]]

    cond do
      Enum.all?(options, &is_nil/1) ->
        {:ok, nil}

      Enum.all?(options, &is_binary/1) ->
        {:ok,
         %{
           ip: values[:listen_ip],
           public_origin: values[:public_origin],
           cert_source: values[:tls_cert],
           key_source: values[:tls_key],
           runtime_certfile: Path.join(runtime_root, "tls-cert.pem"),
           runtime_keyfile: Path.join(runtime_root, "tls-key.pem")
         }}

      true ->
        {:error, :invalid_arguments}
    end
  end

  defp provision_service(directory, runtime_root, instance, scope, port, expires_at, nil) do
    input = service_input(directory, runtime_root, instance, scope, port, expires_at)

    case HostProvisioning.initialize(Map.put(input, :ip, "127.0.0.1")) do
      {:ok, paths} -> {:ok, %{host: paths, tls: nil}}
      {:error, _} = error -> error
    end
  end

  defp provision_service(directory, runtime_root, instance, scope, port, expires_at, tls) do
    input =
      directory
      |> service_input(runtime_root, instance, scope, port, expires_at)
      |> Map.merge(%{
        ip: tls.ip,
        public_origin: tls.public_origin,
        certfile: tls.runtime_certfile,
        keyfile: tls.runtime_keyfile
      })

    case HostProvisioning.initialize_tls(input) do
      {:ok, paths} -> provision_tls(paths, directory, runtime_root, tls)
      {:error, _} = error -> error
    end
  end

  defp service_input(directory, runtime_root, instance, scope, port, expires_at) do
    %{
      destination_root: directory,
      runtime_root: runtime_root,
      instance_id: instance,
      scope: scope,
      port: port,
      expires_at: expires_at
    }
  end

  defp provision_tls(paths, directory, runtime_root, tls) do
    case TLSProvisioning.provision(
           directory,
           runtime_root,
           tls.cert_source,
           tls.key_source
         ) do
      {:ok, tls_paths} ->
        {:ok, %{host: paths, tls: tls_paths}}

      {:error, _} = error ->
        discard_host_paths(paths)
        error
    end
  end

  defp provision_storage(service, directory, runtime_root, instance) do
    case StoragePolicy.provision(directory, runtime_root, instance) do
      {:ok, marker} ->
        {:ok, marker}

      {:error, _} = error ->
        discard_service(service)
        error
    end
  end

  defp provision_browser(_service, _marker, _directory, nil, _scope), do: {:ok, nil}

  defp provision_browser(service, marker, directory, port, scope) do
    case BrowserProvisioning.provision(directory, port, scope) do
      {:ok, browser} ->
        {:ok, browser}

      {:error, _} = error ->
        File.rm(marker)
        discard_service(service)
        error
    end
  end

  defp add_tls_result(result, nil), do: result

  defp add_tls_result(result, tls) do
    Map.merge(result, %{
      "tls_certificate_file" => tls.certfile,
      "tls_private_key_file" => tls.keyfile,
      "runtime_tls_certificate_file" => tls.runtime_certfile,
      "runtime_tls_private_key_file" => tls.runtime_keyfile
    })
  end

  defp discard_service(%{host: paths, tls: tls}) do
    if tls do
      _ = [File.rm(tls.certfile), File.rm(tls.keyfile)]
    end

    discard_host_paths(paths)
  end

  defp discard_host_paths(paths) do
    _ = [
      File.rm(paths.config),
      File.rm(paths.token_file),
      File.rmdir(paths.data_directory),
      File.rmdir(Path.dirname(paths.config))
    ]

    :ok
  end
end
