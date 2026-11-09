defmodule Mix.Tasks.Stampede.Report do
  @shortdoc "Writes the HTML report of results saved as JSON"

  @moduledoc """
  Writes the HTML report of a run saved with `mix stampede.run --out`, so you
  can look at an old run again, or with a newer Stampede's report.

      $ mix stampede.report results.json
      $ mix stampede.report results.json --html old-run.html

  ## Options

    * `--html` - where to write the report, `report.html` next to the JSON
      file by default
  """

  use Mix.Task

  alias Stampede.Reporter

  @impl true
  def run(args) do
    {opts, files} = OptionParser.parse!(args, strict: [html: :string])

    file =
      case files do
        [file] ->
          file

        _other ->
          Mix.raise("Expected one results file, such as: mix stampede.report results.json")
      end

    results =
      try do
        file |> File.read!() |> Reporter.from_json()
      rescue
        error in [File.Error, JSON.DecodeError, KeyError, ArgumentError] ->
          Mix.raise("Could not read #{file} as results: #{Exception.message(error)}")
      end

    html = opts[:html] || Path.join(Path.dirname(file), "report.html")
    File.write!(html, Reporter.to_html(results))
    Mix.shell().info("Wrote #{html}")
  end
end
