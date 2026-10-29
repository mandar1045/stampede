defmodule Mix.Tasks.Stampede.Compare do
  @shortdoc "Compares the results of two load test runs"

  @moduledoc """
  Compares the timings of two runs, from files written by
  `mix stampede.run --out`.

      $ mix stampede.compare main.json branch.json
      $ mix stampede.compare main.json branch.json --max-regression 10

  For every scenario and timing in both files, prints the p50, p95 and p99
  of each run and how much they changed.

  ## Options

    * `--max-regression` - how many percent slower a percentile may get. The
      task exits with status 1 when one gets slower than that, so it can gate
      CI.
    * `--format` - `text`, the default, or `markdown`, to post the comparison
      as a comment on a pull request, such as with
      `gh pr comment --body-file`

  Keep in mind that timings vary from one run to the next, even with no
  change to the code, so leave some room. Runs of a minute or more on the
  same machine compare best.
  """

  use Mix.Task

  alias Stampede.Reporter

  @stats ["p50", "p95", "p99"]

  @impl true
  def run(args) do
    {opts, files} = OptionParser.parse!(args, strict: [max_regression: :float, format: :string])

    format =
      case opts[:format] || "text" do
        "text" -> :text
        "markdown" -> :markdown
        other -> Mix.raise("Expected --format to be text or markdown, got: #{other}")
      end

    {base_file, head_file} =
      case files do
        [base, head] ->
          {base, head}

        _other ->
          Mix.raise(
            "Expected two result files, such as: mix stampede.compare main.json branch.json"
          )
      end

    limit = opts[:max_regression]
    base = read!(base_file)

    regressions =
      for {scenario, head_run} <- Enum.sort(read!(head_file)), reduce: 0 do
        regressions ->
          case Map.fetch(base, scenario) do
            {:ok, base_run} ->
              {lines, count} = compare(base_run, head_run, limit, format)
              lines = lines |> IO.iodata_to_binary() |> String.trim_trailing()
              title = if format == :markdown, do: "### #{scenario}\n", else: scenario
              Mix.shell().info(["\n", title, "\n", lines])
              regressions + count

            :error ->
              Mix.shell().info("\n#{scenario} is not in #{base_file}, skipping it")
              regressions
          end
      end

    cond do
      limit == nil ->
        :ok

      regressions == 0 ->
        Mix.shell().info("\nNo percentile got more than #{percent(limit)} slower")

      true ->
        Mix.shell().error("\n#{regressions} percentiles got more than #{percent(limit)} slower")
        exit({:shutdown, 1})
    end
  end

  defp compare(base, head, limit, format) do
    rows =
      for {name, %{"type" => "timing"} = new} <- Enum.sort(head["metrics"]),
          %{"type" => "timing"} = old <- [base["metrics"][name]],
          stat <- @stats do
        change = change(old[stat], new[stat])
        regressed? = limit != nil and change > limit

        row = [
          name,
          stat,
          Reporter.milliseconds(old[stat]),
          Reporter.milliseconds(new[stat]),
          signed(change)
        ]

        {if(regressed?, do: row ++ ["FAIL"], else: row), regressed?}
      end

    header = ["metric", "stat", "base", "head", "change"]
    count = Enum.count(rows, &elem(&1, 1))

    case {rows, format} do
      {[], :text} ->
        {["  no timings to compare\n"], 0}

      {[], :markdown} ->
        {["No timings to compare.\n"], 0}

      {rows, :text} ->
        {Reporter.table([header | Enum.map(rows, &elem(&1, 0))]), count}

      {rows, :markdown} ->
        {markdown_table(header, Enum.map(rows, &elem(&1, 0))), count}
    end
  end

  # A regression is marked in bold in its change column.
  defp markdown_table(header, rows) do
    lines =
      for row <- rows do
        cells =
          case row do
            [name, stat, old, new, change, "FAIL"] -> [name, stat, old, new, "**#{change} FAIL**"]
            cells -> cells
          end

        ["| ", Enum.join(cells, " | "), " |\n"]
      end

    ["| ", Enum.join(header, " | "), " |\n", "|---|---|---:|---:|---:|\n" | lines]
  end

  defp change(old, _new) when old == 0, do: 0.0
  defp change(old, new), do: (new - old) / old * 100

  defp signed(change) when change >= 0, do: "+" <> percent(change)
  defp signed(change), do: percent(change)

  defp percent(value), do: :erlang.float_to_binary(value / 1, decimals: 1) <> "%"

  defp read!(file) do
    runs =
      case File.read(file) do
        {:ok, contents} -> decode!(file, contents)
        {:error, reason} -> Mix.raise("Could not read #{file}: #{:file.format_error(reason)}")
      end

    for run <- List.wrap(runs), into: %{} do
      case run do
        %{"scenario" => scenario, "metrics" => %{}} -> {scenario, run}
        _other -> Mix.raise("Expected #{file} to hold results written by mix stampede.run --out")
      end
    end
  end

  defp decode!(file, contents) do
    case JSON.decode(contents) do
      {:ok, runs} -> runs
      {:error, _reason} -> Mix.raise("Could not decode #{file} as JSON")
    end
  end
end
