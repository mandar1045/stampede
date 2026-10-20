defmodule Mix.Tasks.Stampede.Run do
  @shortdoc "Runs load test scenarios"

  @moduledoc """
  Runs the load test scenarios defined in a file.

      $ mix stampede.run loadtest/lobby.exs
      $ mix stampede.run loadtest/lobby.exs --vus 100 --duration 1m

  Every module in the file that implements `Stampede.Scenario` runs, one
  after the other, with a progress line every second and a summary at the
  end. The task exits with status 1 when a threshold fails, so it can gate CI.

  Your project is compiled and configured, but its application is not
  started, since the system under test usually runs somewhere else. Start
  it in `c:Stampede.Scenario.setup/1` if a scenario needs it.

  ## Options

    * `--vus` - how many VUs to run at once
    * `--duration` - how long to run them, such as `500ms`, `30s`, `5m` or `1h`

  Giving either one replaces the scenario's `:stages` with a constant number
  of VUs.
  """

  use Mix.Task

  @switches [vus: :integer, duration: :string]

  @impl true
  def run(args) do
    {opts, files} = OptionParser.parse!(args, strict: @switches)

    if files == [] do
      Mix.raise("Expected a scenario file, such as: mix stampede.run loadtest/lobby.exs")
    end

    overrides = overrides(opts)
    Mix.Task.run("app.config")
    {:ok, _apps} = Application.ensure_all_started(:stampede)

    results =
      for file <- files, scenario <- scenarios!(file) do
        result = Stampede.run(scenario, [progress: true] ++ overrides)
        Mix.shell().info(["\n", Stampede.Reporter.format(result)])
        result
      end

    if not Enum.all?(results, & &1.passed?) do
      exit({:shutdown, 1})
    end
  end

  defp overrides(opts) do
    opts =
      opts
      |> Keyword.take([:vus, :duration])
      |> Keyword.replace_lazy(:duration, &parse_duration!/1)

    if opts == [], do: [], else: [stages: nil] ++ opts
  end

  defp parse_duration!(duration) do
    case Integer.parse(duration) do
      {value, "ms"} when value >= 0 -> value
      {value, "s"} when value >= 0 -> to_timeout(second: value)
      {value, "m"} when value >= 0 -> to_timeout(minute: value)
      {value, "h"} when value >= 0 -> to_timeout(hour: value)
      _other -> Mix.raise("Expected --duration like 500ms, 30s, 5m or 1h, got: #{duration}")
    end
  end

  defp scenarios!(file) do
    if not File.regular?(file) do
      Mix.raise("Could not find scenario file #{file}")
    end

    scenarios = for {module, _binary} <- Code.compile_file(file), scenario?(module), do: module

    if scenarios == [] do
      Mix.raise("No module in #{file} implements Stampede.Scenario")
    end

    scenarios
  end

  defp scenario?(module) do
    behaviours =
      module.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    Stampede.Scenario in behaviours
  end
end
