defmodule WotexMobileSecureStore.MixProject do
  use Mix.Project

  def project do
    [
      app: :wotex_mobile_secure_store,
      version: "0.1.0",
      elixir: "~> 1.19",
      description: "Closed iOS Keychain bridge for the WoTEx mobile host",
      package: [
        licenses: ["Apache-2.0"],
        files: ~w(lib src priv mix.exs README.md)
      ],
      deps: []
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
