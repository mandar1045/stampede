defmodule Mix.Tasks.Stampede.Install.Docs do
  @moduledoc false

  def short_doc, do: "Installs Stampede into a project"

  def example, do: "mix igniter.install stampede"

  def long_doc do
    """
    #{short_doc()}, with [Igniter](https://hexdocs.pm/igniter):

        $ #{example()}

    Adds Stampede to the dependencies of the `dev` and `test` environments,
    and creates `loadtest/home.exs`, a scenario that requests the home page of
    your app, to start from. Run it with:

        $ mix stampede.run loadtest/home.exs --dashboard

    `mix stampede.gen.scenario` generates scenarios for Phoenix Channels,
    LiveView and plain WebSockets.
    """
  end
end

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Stampede.Install do
    @shortdoc __MODULE__.Docs.short_doc()
    @moduledoc __MODULE__.Docs.long_doc()

    use Igniter.Mix.Task

    alias Mix.Tasks.Stampede.Gen.Scenario

    @path "loadtest/home.exs"

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :stampede,
        example: __MODULE__.Docs.example(),
        only: [:dev, :test]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      module = igniter |> Igniter.Project.Module.module_name("Load.Home") |> inspect()

      igniter
      |> Igniter.create_new_file(@path, Scenario.scenario(:http, module, @path), on_exists: :skip)
      |> Igniter.add_notice("""
      Stampede is installed. Run your first load test, and watch it at
      http://127.0.0.1:4040, with:

          mix stampede.run #{@path} --dashboard

      Generate scenarios for channels and LiveViews with
      mix stampede.gen.scenario. The docs are at https://stampede.hexdocs.pm
      """)
    end
  end
else
  defmodule Mix.Tasks.Stampede.Install do
    @shortdoc "#{__MODULE__.Docs.short_doc()} | Install `igniter` to use"
    @moduledoc __MODULE__.Docs.long_doc()

    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      The task 'stampede.install' requires Igniter. Add Stampede to your
      dependencies by hand instead, as the README shows, or install Igniter:
      https://hexdocs.pm/igniter/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
