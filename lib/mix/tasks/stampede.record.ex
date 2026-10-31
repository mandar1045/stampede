defmodule Mix.Tasks.Stampede.Record do
  @shortdoc "Records a session in the browser as a load test scenario"

  @moduledoc """
  Starts your Phoenix app and records what you do in it, then writes it as a
  scenario.

      $ mix stampede.record Checkout

  Open the app in your browser, click through what a user would do, and press
  Enter in the terminal when you're done. That writes `loadtest/checkout.exs`,
  with your clicks, forms, navigation and pauses, ready for
  `mix stampede.run`.

  Passwords and other fields that look sensitive are replaced with
  `"CHANGE_ME"`. The [recording guide](recording.html) has what's recorded and
  what isn't.

  ## Options

    * `--force` - overwrites the file without asking
  """

  use Mix.Task

  alias Stampede.Recorder

  @impl true
  def run(args), do: run(args, fn -> IO.gets("") end)

  # `wait` returns once the person is done.
  @doc false
  def run(args, wait) do
    {opts, names} = OptionParser.parse!(args, strict: [force: :boolean])

    name =
      case names do
        [name] -> name
        _other -> Mix.raise("Expected a scenario name, such as: mix stampede.record Checkout")
      end

    if not (name =~ ~r/^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)*$/) do
      Mix.raise("Expected the scenario name to be a module name, such as Checkout, got: #{name}")
    end

    Application.put_env(:phoenix, :serve_endpoints, true, persistent: true)
    Mix.Task.run("app.start")
    {:ok, _apps} = Application.ensure_all_started(:stampede)
    {:ok, recorder} = Recorder.start()

    Mix.shell().info("""

    Recording. Open your app in a browser and do what a user would do.
    Press Enter here when you're done.
    """)

    wait.()
    steps = Recorder.stop(recorder)

    if steps == [] do
      Mix.raise("Nothing was recorded. Was the app open in a browser?")
    end

    path = Path.join("loadtest", Macro.underscore(name) <> ".exs")
    module = Enum.join([namespace(), Macro.camelize(name)], ".")

    if Mix.Generator.create_file(path, Recorder.to_scenario(steps, module), force: opts[:force]) do
      Mix.shell().info(
        "\nRecorded #{length(steps)} steps. Run them with:\n\n    $ mix stampede.run #{path}\n"
      )
    end
  end

  defp namespace do
    case Mix.Project.config()[:app] do
      nil -> "Load"
      app -> Macro.camelize(Atom.to_string(app)) <> ".Load"
    end
  end
end
