defmodule Wotex.Tracker.Mobile.ExternalURL do
  @moduledoc """
  Admits a blocked WebView navigation for the OS-owned external browser.

  Only canonical HTTPS URLs without embedded credentials are admitted. Other
  schemes remain blocked and receive no native bridge privilege.
  """

  @maximum_bytes 2_048

  @doc "Validates one external navigation target."
  @spec admit(term()) :: {:ok, String.t()} | {:error, :invalid_url}
  def admit(url) when is_binary(url) and byte_size(url) in 1..@maximum_bytes do
    uri = URI.parse(url)

    with "https" <- uri.scheme,
         host when is_binary(host) and host != "" <- uri.host,
         true <- is_nil(uri.userinfo),
         port when port in 1..65_535 <- uri.port || 443,
         normalized = %URI{uri | scheme: "https", host: String.downcase(host), port: port},
         canonical = URI.to_string(%{normalized | port: if(port == 443, do: nil, else: port)}),
         true <- canonical == url do
      {:ok, canonical}
    else
      _ -> {:error, :invalid_url}
    end
  end

  def admit(_), do: {:error, :invalid_url}
end
