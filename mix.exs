defmodule Stampede.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/mandar1045/stampede"

  def project do
    [
      app: :stampede,
      version: @version,
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Load testing for Phoenix, with built-in Channels and LiveView support",
      package: package(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:mint, "~> 1.6"},
      {:mint_web_socket, "~> 1.0"},
      {:phoenix, "~> 1.7", only: :test},
      {:phoenix_live_view, "~> 1.0", only: :test},
      {:bandit, "~> 1.0", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md"],
      groups_for_modules: [
        Clients: [Stampede.Channels, Stampede.LiveView],
        Results: [Stampede.Result, Stampede.Reporter]
      ]
    ]
  end
end
