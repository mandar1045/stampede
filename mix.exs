defmodule Stampede.MixProject do
  use Mix.Project

  @version "1.2.0"
  @source_url "https://github.com/mandar1045/stampede"

  def project do
    [
      app: :stampede,
      version: @version,
      elixir: "~> 1.18",
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
      mod: {Stampede.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:mint, "~> 1.6"},
      {:mint_web_socket, "~> 1.0"},
      {:telemetry, "~> 1.0"},
      {:igniter, "~> 0.8", optional: true},
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
      extras: [
        "README.md",
        "guides/login.md",
        "guides/presence.md",
        "guides/absinthe.md",
        "guides/ci.md",
        "guides/distributed.md",
        "guides/llm.md",
        "guides/probe.md",
        "guides/supabase_realtime.md",
        "CHANGELOG.md",
        "CONTRIBUTING.md"
      ],
      groups_for_extras: [Guides: ~r"guides/"],
      assets: %{"assets" => "assets"},
      groups_for_modules: [
        Clients: [
          Stampede.HTTP,
          Stampede.Channels,
          Stampede.LiveView,
          Stampede.WebSocket,
          Stampede.SSE,
          Stampede.LLM
        ],
        "Channels protocol": [
          Stampede.Channels.Serializer,
          Stampede.Channels.Serializer.V2,
          Stampede.Channels.Serializer.V1,
          Stampede.Channels.Message
        ],
        Results: [Stampede.Result, Stampede.Reporter, Stampede.Dashboard]
      ]
    ]
  end
end
