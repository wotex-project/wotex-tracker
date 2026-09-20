defmodule Wotex.Tracker.Nerves.FirmwareHealth do
  @moduledoc """
  Synchronously proves the core appliance is healthy before application startup completes.

  Nerves Runtime's startup guard validates pending firmware only after all OTP
  applications report that they started. Keeping this check in the Tracker
  application startup path makes firmware validation depend on the initialized
  storage identity, an actual bound listener and a writable current-schema store.
  """

  alias Wotex.Tracker.Nerves.StoragePolicy
  alias Wotex.Tracker.Service.HTTP.Server
  alias Wotex.Tracker.Service.{Schema, Store}

  @error {:error, :firmware_health_failed}

  @doc "Checks the live core service without exposing configuration or storage details."
  @spec check(term(), term(), term(), term()) :: :ok | {:error, :firmware_health_failed}
  def check(host, root, instance_id, data_directory) do
    with true <- is_pid(host) and Process.alive?(host),
         true <- StoragePolicy.initialized?(root, instance_id, data_directory),
         {:ok, server} <- Server.child(host, Server),
         {:ok, {ip, port}} <- Server.listener_info(server),
         true <- listener?(ip, port),
         {:ok, store} <- Server.child(server, :store),
         {:ok, readiness} <- Store.readiness(Store.handle(store)),
         true <- ready?(readiness) do
      :ok
    else
      _ -> @error
    end
  rescue
    _ -> @error
  catch
    :exit, _ -> @error
    _, _ -> @error
  end

  defp listener?(ip, port) when is_tuple(ip) and tuple_size(ip) in [4, 8],
    do: is_integer(port) and port in 1..65_535

  defp listener?(_, _), do: false

  defp ready?(%{"writable" => true, "schema" => schema, "sqlite" => sqlite})
       when is_binary(sqlite) and byte_size(sqlite) > 0,
       do: schema == Integer.to_string(Schema.current_version())

  defp ready?(_), do: false
end
