defmodule Mix.Tasks.Stampede.Run do
  @shortdoc "Runs load test scenarios"

  @moduledoc """
  Runs the load test scenarios defined in a file.

      $ mix stampede.run loadtest/lobby.exs
      $ mix stampede.run loadtest/lobby.exs --vus 100 --duration 1m
      $ mix stampede.run loadtest/api.exs --rate 200 --duration 5m --out results.json
      $ mix stampede.run loadtest/api.exs --html report.html

  Every module in the file that implements `Stampede.Scenario` runs, one
  after the other, with a progress line every second and a summary at the
  end. The task exits with status 1 when a threshold fails, so it can gate CI.

  Your project is compiled and configured, but its application is not
  started, since the system under test usually runs somewhere else. Start
  it in `c:Stampede.Scenario.setup/1` if a scenario needs it.

  ## Options

    * `--vus` - how many VUs to run at once
    * `--rate` - how many iterations to start per second, instead of `--vus`
    * `--duration` - how long to run, such as `500ms`, `30s`, `5m` or `1h`
    * `--max-vus` - how many iterations a `--rate` run may have in progress
    * `--out` - a file to write the results to, as a JSON array with one
      object per scenario, in the format of `Stampede.Reporter.to_json/1`
    * `--html` - a file to write an HTML report of every scenario to, with
      charts of how each run went, see `Stampede.Reporter.to_html/1`
    * `--nodes` - other nodes to run VUs on too, separated by commas

  `--vus` and `--rate` replace the scenario's own VUs, rate and stages, and
  `--duration` replaces its stages.

  ## Running on several machines

  Start a node on every machine, from the same project, and the task with
  a name and the same cookie:

      $ iex --sname worker --cookie load -S mix
      $ elixir --sname loader --cookie load -S mix stampede.run loadtest/lobby.exs --nodes worker@host

  The VUs are split evenly between the task's node and the given ones, and
  the scenarios in the file are loaded on all of them.
  """

  use Mix.Task

  @switches [
    vus: :integer,
    rate: :float,
    duration: :string,
    max_vus: :integer,
    out: :string,
    html: :string,
    nodes: :string
  ]

  @impl true
  def run(args) do
    {opts, files} = OptionParser.parse!(args, strict: @switches)

    if files == [] do
      Mix.raise("Expected a scenario file, such as: mix stampede.run loadtest/lobby.exs")
    end

    overrides = overrides(opts)
    nodes = connect!(opts[:nodes])
    Mix.Task.run("app.config")
    {:ok, _apps} = Application.ensure_all_started(:stampede)

    results =
      for file <- files, scenario <- scenarios!(file, nodes) do
        opts = Keyword.merge([progress: true, nodes: [node() | nodes]], overrides)
        result = Stampede.run(scenario, opts)
        Mix.shell().info(["\n", Stampede.Reporter.format(result)])
        result
      end

    if out = opts[:out] do
      File.write!(out, [
        "[",
        Enum.map_intersperse(results, ",", &Stampede.Reporter.to_json/1),
        "]"
      ])
    end

    if html = opts[:html] do
      File.write!(html, Stampede.Reporter.to_html(results))
    end

    if not Enum.all?(results, & &1.passed?) do
      exit({:shutdown, 1})
    end
  end

  defp overrides(opts) do
    if opts[:vus] && opts[:rate] do
      Mix.raise("Expected either --vus or --rate, not both")
    end

    Enum.reduce(opts, [], fn
      {:vus, vus}, overrides ->
        Keyword.merge(overrides, stages: nil, rate: nil, rate_stages: nil, vus: vus)

      {:rate, rate}, overrides ->
        Keyword.merge(overrides, stages: nil, rate_stages: nil, rate: rate)

      {:duration, duration}, overrides ->
        Keyword.merge(overrides,
          stages: nil,
          rate_stages: nil,
          duration: parse_duration!(duration)
        )

      {:max_vus, max_vus}, overrides ->
        Keyword.put(overrides, :max_vus, max_vus)

      {_option, _value}, overrides ->
        overrides
    end)
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

  defp connect!(nil), do: []

  defp connect!(nodes) do
    if not Node.alive?() do
      Mix.raise(
        "Expected the task to run on a named node to use --nodes, such as: " <>
          "elixir --sname loader --cookie load -S mix stampede.run ..."
      )
    end

    for name <- String.split(nodes, ",", trim: true) do
      node = name |> String.trim() |> String.to_atom()

      if not Node.connect(node) do
        Mix.raise("Could not connect to #{node}, check that it is running with the same cookie")
      end

      node
    end
  end

  defp scenarios!(file, nodes) do
    if not File.regular?(file) do
      Mix.raise("Could not find scenario file #{file}")
    end

    modules = Code.compile_file(file)

    for node <- nodes, {module, binary} <- modules do
      {:module, ^module} =
        :erpc.call(node, :code, :load_binary, [module, to_charlist(file), binary])
    end

    scenarios = for {module, _binary} <- modules, scenario?(module), do: module

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
