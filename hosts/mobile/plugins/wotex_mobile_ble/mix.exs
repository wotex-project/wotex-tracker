defmodule WotexMobileBLE.MixProject do
  use Mix.Project

  def project do
    [
      app: :wotex_mobile_ble,
      version: "0.1.0",
      elixir: "~> 1.19",
      description: "Closed iOS CoreBluetooth central bridge for the WoTEx mobile host",
      package: [
        licenses: ["Apache-2.0"],
        files: ~w(lib src priv mix.exs README.md)
      ],
      deps: [{:jason, "== 1.4.5"}]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
