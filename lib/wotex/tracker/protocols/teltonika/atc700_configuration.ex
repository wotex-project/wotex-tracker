defmodule Wotex.Tracker.Protocols.Teltonika.ATC700Configuration do
  @moduledoc """
  Closed documentation-backed provisioning plan for the ATC700 profile.

  ATC700 SMS authentication has one password field, unlike the TAT140 login
  and password prefix. The plan binds the documented mobile-network parameters
  to an operator-controlled TCP endpoint and also fixes the tracking settings
  to Codec 8 Extended with AVL server confirmation. It emits a transient TCT
  manifest for review; it does not claim that a physical device accepted it.
  """

  alias Wotex.Tracker.Protocols.Teltonika.ATC700

  @maximum_sms_bytes 160
  @provisioning_path "sms_and_teltonika_configurator_tct"
  @sources [
    "https://wiki.teltonika-gps.com/view/ATC700_SMS/GPRS_Command_List",
    "https://wiki.teltonika-gps.com/view/ATC700_SMS/call_settings",
    "https://wiki.teltonika-gps.com/view/ATC700_Mobile_network",
    "https://wiki.teltonika-gps.com/view/ATC700_Tracking_settings",
    "https://wiki.teltonika-gps.com/view/ATC700_Parameter_List"
  ]

  @derive {Inspect,
           only: [
             :provisioning_path,
             :server,
             :port,
             :transport,
             :data_protocol,
             :server_confirmation
           ]}
  @enforce_keys [
    :provisioning_path,
    :sms_password,
    :apn,
    :apn_username,
    :apn_password,
    :server,
    :port,
    :transport,
    :data_protocol,
    :server_confirmation
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          provisioning_path: String.t(),
          sms_password: String.t(),
          apn: String.t(),
          apn_username: String.t(),
          apn_password: String.t(),
          server: String.t(),
          port: :inet.port_number(),
          transport: :tcp,
          data_protocol: :codec8_extended,
          server_confirmation: :avl
        }

  @doc "Admits one exact password-only ATC700 cellular configuration."
  @spec new(term()) :: {:ok, t()} | {:error, :invalid_configuration}
  def new(
        %{
          "schema" => "wtr.atc700-configuration.v1",
          "provisioning_path" => @provisioning_path,
          "sms" => %{"password" => sms_password} = sms,
          "cellular" =>
            %{
              "apn" => apn,
              "username" => apn_username,
              "password" => apn_password,
              "server" => server,
              "port" => port,
              "transport" => "tcp"
            } = cellular,
          "protocol" =>
            %{
              "data" => "codec8_extended",
              "server_confirmation" => "avl"
            } = protocol
        } = document
      )
      when map_size(document) == 5 and map_size(sms) == 1 and map_size(cellular) == 6 and
             map_size(protocol) == 2 do
    config = %__MODULE__{
      provisioning_path: @provisioning_path,
      sms_password: sms_password,
      apn: apn,
      apn_username: apn_username,
      apn_password: apn_password,
      server: server,
      port: port,
      transport: :tcp,
      data_protocol: :codec8_extended,
      server_confirmation: :avl
    }

    if valid?(config), do: {:ok, config}, else: {:error, :invalid_configuration}
  end

  def new(_), do: {:error, :invalid_configuration}

  @doc "Renders the ordered, independently bounded ATC700 SMS command batch."
  @spec endpoint_sms_commands(t()) :: [String.t()]
  def endpoint_sms_commands(%__MODULE__{} = config) do
    prefix = sms_prefix(config)

    [
      prefix <>
        "setparam 2025:0;2001:#{config.apn};2002:#{config.apn_username};2003:#{config.apn_password}",
      prefix <> "setparam 2004:#{config.server};2005:#{config.port};2006:0",
      prefix <> "setparam 1004:1;113:0"
    ]
  end

  @doc "Renders a bounded read-back command for every non-secret configured parameter."
  @spec endpoint_verification_sms(t()) :: String.t()
  def endpoint_verification_sms(%__MODULE__{} = config),
    do: sms_prefix(config) <> "getparam 2025;2001;2004;2005;2006;1004;113"

  @doc "Returns expected values for the non-secret SMS read-back."
  @spec endpoint_expectations(t()) :: map()
  def endpoint_expectations(%__MODULE__{} = config),
    do: %{
      "113" => 0,
      "1004" => 1,
      "2001" => config.apn,
      "2004" => config.server,
      "2005" => config.port,
      "2006" => 0,
      "2025" => 0
    }

  @doc "Returns corresponding transient TCT selections with manual APN mode made explicit."
  @spec configurator_manifest(t()) :: map()
  def configurator_manifest(%__MODULE__{} = config) do
    %{
      "schema" => "wtr.atc700-tct-manifest.v1",
      "provisioning_path" => config.provisioning_path,
      "profile" => ATC700.configured_profile(),
      "sources" => @sources,
      "sms_call" => %{
        "sms_security" => %{
          "authentication" => "Password only",
          "password" => config.sms_password
        }
      },
      "mobile_network" => %{
        "mobile_data" => %{
          "auto_apn" => "Disabled",
          "apn" => config.apn,
          "apn_username" => config.apn_username,
          "apn_password" => config.apn_password
        },
        "primary_server" => %{
          "domain" => config.server,
          "port" => config.port,
          "data_protocol" => "TCP"
        }
      },
      "tracking" => %{
        "records" => %{
          "data_protocol" => "Codec 8 Extended",
          "server_confirmation_method" => "AVL"
        }
      }
    }
  end

  defp valid?(config) do
    sms_password?(config.sms_password) and endpoint_parameters?(config) and bounded?(config)
  end

  defp sms_password?(""), do: true

  defp sms_password?(password),
    do: parameter?(password, 5..10, ~r/\A[A-Za-z0-9]+\z/)

  defp endpoint_parameters?(config) do
    parameter?(config.apn, 1..32, ~r/\A[A-Za-z0-9.-]+\z/) and
      parameter?(config.apn_username, 0..32, ~r/\A[A-Za-z0-9._@+-]*\z/) and
      parameter?(config.apn_password, 0..32, ~r/\A[A-Za-z0-9._@+-]*\z/) and
      parameter?(config.server, 1..55, ~r/\A[A-Za-z0-9.-]+\z/) and
      is_integer(config.port) and config.port in 1..65_535
  end

  defp parameter?(value, range, pattern),
    do: is_binary(value) and byte_size(value) in range and Regex.match?(pattern, value)

  defp sms_prefix(%__MODULE__{sms_password: ""}), do: " "
  defp sms_prefix(%__MODULE__{sms_password: password}), do: password <> " "

  defp bounded?(config) do
    Enum.all?(endpoint_sms_commands(config) ++ [endpoint_verification_sms(config)], fn command ->
      byte_size(command) <= @maximum_sms_bytes
    end)
  end
end
