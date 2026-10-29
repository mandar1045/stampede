defmodule Load.MixProject do
  use Mix.Project

  def project do
    [
      app: :load,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: [{:stampede, path: "../../.."}]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
