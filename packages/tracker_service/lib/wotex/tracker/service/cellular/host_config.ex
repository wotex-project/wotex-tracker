defmodule Wotex.Tracker.Service.Cellular.HostConfig do
  @moduledoc """
  Closed private host configuration for one Teltonika TCP listener.

  The configuration stores routing digests, a keyed-identity secret and service
  bearers, so its inspection is deliberately redacted. It selects one closed
  packaged Teltonika asset-tracker contract; device traffic cannot choose a
  decoder.
  """

  alias Wotex.Tracker.Protocols.Teltonika.{ATC700, TAT140}
  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.{Codec, Credentials}

  @derive {Inspect, only: [:ip, :port]}
  @enforce_keys [:ip, :port, :identity_key, :devices]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          ip: :inet.ip_address(),
          port: :inet.port_number(),
          identity_key: binary(),
          devices: [map()]
        }

  @doc "Admits one bounded private listener document against service credentials."
  @spec new(term(), term(), term()) :: {:ok, t() | nil} | {:error, :invalid_configuration}
  def new(nil, _credentials, _contract), do: {:ok, nil}

  def new(
        %{
          "schema" => "wtr.cellular-host.v1",
          "transport" => "clear_tcp",
          "listen" => listen,
          "identity_key" => encoded_key,
          "devices" => devices
        } = document,
        credentials,
        contract
      )
      when map_size(document) == 5 and
             contract in [:teltonika_tat140_codec8e, :teltonika_atc700_codec8e] do
    with {:ok, credentials} <- Credentials.validate(credentials),
         {:ok, ip, port} <- listen(listen),
         {:ok, identity_key} <- identity_key(encoded_key),
         {:ok, profile} <- configured_profile(contract),
         {:ok, devices} <- devices(devices, credentials, profile) do
      {:ok,
       %__MODULE__{
         ip: ip,
         port: port,
         identity_key: identity_key,
         devices: devices
       }}
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  def new(_, _, _), do: {:error, :invalid_configuration}

  @doc false
  @spec server_options(t(), Service.t() | (-> {:ok, Service.t()} | {:error, term()})) :: keyword()
  def server_options(%__MODULE__{} = config, service) do
    [
      service: service,
      identity_key: config.identity_key,
      devices: config.devices,
      ip: config.ip,
      port: config.port
    ]
  end

  defp listen(%{"ip" => address, "port" => port} = listen)
       when map_size(listen) == 2 and is_binary(address) and is_integer(port) and
              port in 0..65_535 do
    case :inet.parse_strict_address(String.to_charlist(address)) do
      {:ok, ip} -> {:ok, ip, port}
      _ -> {:error, :invalid_configuration}
    end
  end

  defp listen(_), do: {:error, :invalid_configuration}

  defp identity_key(value) when is_binary(value) do
    case Base.decode64(value) do
      {:ok, key} when byte_size(key) == 32 ->
        if Base.encode64(key) == value,
          do: {:ok, key},
          else: {:error, :invalid_configuration}

      _ ->
        {:error, :invalid_configuration}
    end
  end

  defp identity_key(_), do: {:error, :invalid_configuration}

  defp devices(devices, credentials, profile)
       when is_list(devices) and devices != [] and length(devices) <= 32 do
    with {:ok, admitted} <- admit_devices(devices, credentials, profile, []),
         true <- unique?(admitted, :identity_digest),
         true <- unique?(admitted, :id) do
      {:ok, Enum.reverse(admitted)}
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  defp devices(_, _, _), do: {:error, :invalid_configuration}

  defp admit_devices([], _credentials, _profile, admitted), do: {:ok, admitted}

  defp admit_devices([device | rest], credentials, profile, admitted) do
    case device(device, credentials, profile) do
      {:ok, value} -> admit_devices(rest, credentials, profile, [value | admitted])
      error -> error
    end
  end

  defp device(
         %{
           "identity_digest" => digest,
           "token" => token,
           "scope" => scope,
           "id" => id,
           "profile" => profile
         } = device,
         credentials,
         configured_profile
       )
       when map_size(device) == 5 do
    with true <- digest?(digest),
         true <- Codec.id?(scope) and Codec.id?(id),
         true <- profile == configured_profile,
         true <- Credentials.configured?(credentials, token, scope, "ingest") do
      {:ok,
       %{
         identity_digest: digest,
         token: token,
         scope: scope,
         id: id,
         profile: profile
       }}
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  defp device(_, _, _), do: {:error, :invalid_configuration}

  defp configured_profile(:teltonika_tat140_codec8e),
    do: {:ok, TAT140.configured_profile()}

  defp configured_profile(:teltonika_atc700_codec8e),
    do: {:ok, ATC700.configured_profile()}

  defp digest?(digest) when is_binary(digest) and byte_size(digest) == 64,
    do: match?({:ok, _}, Base.decode16(digest, case: :lower))

  defp digest?(_), do: false

  defp unique?(values, key),
    do: values |> Enum.map(&Map.fetch!(&1, key)) |> Enum.uniq() |> length() == length(values)
end
