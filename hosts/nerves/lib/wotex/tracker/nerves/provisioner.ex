defmodule Wotex.Tracker.Nerves.Provisioner do
  @moduledoc """
  Prepares a private, create-only service tree for installation on an appliance.

  The generated document always names `/root/tracker` as its runtime root. The
  destination may instead be an offline staging or mounted-media directory.
  Provisioning never emits the bearer token; it reports the private token file.
  """

  alias Wotex.Tracker.Nerves.{BrowserProvisioning, StoragePolicy}
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
          expires_in: :integer
        ]
      )

    values = Map.new(options)
    expires_in = Map.get(values, :expires_in, 86_400)
    port = Map.get(values, :port, 4000)
    browser_port = values[:browser_port]

    with true <- invalid == [] and rest == [],
         directory when is_binary(directory) <- values[:directory],
         true <- Path.type(directory) == :absolute and Path.expand(directory) == directory,
         instance when is_binary(instance) <- values[:instance_id],
         scope when is_binary(scope) <- values[:scope],
         true <- expires_in in 1..@maximum_expiry_seconds,
         true <- port in 1..65_535,
         true <- is_nil(browser_port) or browser_port in 1..65_535,
         true <- is_nil(browser_port) or browser_port != port,
         {:ok, paths} <-
           HostProvisioning.initialize(%{
             destination_root: directory,
             runtime_root: runtime_root,
             instance_id: instance,
             scope: scope,
             ip: "127.0.0.1",
             port: port,
             expires_at: now + expires_in * 1_000
           }),
         {:ok, marker} <- provision_storage(paths, directory, runtime_root, instance),
         {:ok, browser} <- provision_browser(paths, marker, directory, browser_port) do
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

      {:ok, if(browser, do: Map.put(result, "browser_config_file", browser), else: result)}
    else
      false -> {:error, :invalid_arguments}
      nil -> {:error, :invalid_arguments}
      {:error, _} = error -> error
      _ -> {:error, :invalid_arguments}
    end
  end

  def run(_, _, _), do: {:error, :invalid_arguments}

  defp provision_storage(paths, directory, runtime_root, instance) do
    case StoragePolicy.provision(directory, runtime_root, instance) do
      {:ok, marker} ->
        {:ok, marker}

      {:error, _} = error ->
        discard_host_paths(paths)
        error
    end
  end

  defp provision_browser(_paths, _marker, _directory, nil), do: {:ok, nil}

  defp provision_browser(paths, marker, directory, port) do
    case BrowserProvisioning.provision(directory, port) do
      {:ok, browser} ->
        {:ok, browser}

      {:error, _} = error ->
        File.rm(marker)
        discard_host_paths(paths)
        error
    end
  end

  defp discard_host_paths(paths) do
    _ = [File.rm(paths.config), File.rm(paths.token_file), File.rmdir(paths.data_directory)]
    :ok
  end
end
