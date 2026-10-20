defmodule Stampede.Reporter do
  @moduledoc """
  Formats a `Stampede.Result` for the terminal, as JSON or as an HTML page.
  """

  alias Stampede.Result

  @timing_stats [:mean, :p50, :p90, :p95, :p99, :max]

  @doc """
  Returns a summary of `result`, with a line per metric followed by the
  checks, the thresholds and the most frequent errors, if there are any.
  """
  @spec format(Result.t()) :: String.t()
  def format(%Result{} = result) do
    {checks, metrics} = Enum.split_with(result.metrics, &match?({_name, %{type: :check}}, &1))

    IO.iodata_to_binary([
      "#{inspect(result.scenario)} ran for #{seconds(result.duration)}\n",
      metrics(metrics, checks),
      checks(checks),
      thresholds(result.thresholds),
      errors(result.errors)
    ])
  end

  @doc """
  Returns `result` as JSON, with every metric, the timeline, the thresholds
  and the errors.

  Timings are in milliseconds and rates per second, as in `Stampede.Result`.
  """
  @spec to_json(Result.t()) :: String.t()
  def to_json(%Result{} = result) do
    result
    |> Map.from_struct()
    |> Map.update!(:scenario, &inspect/1)
    |> JSON.encode!()
  end

  @doc """
  Returns `results` as an HTML page, with charts of their timelines, along
  with the tables of `format/1`.

  The page is a single file that needs nothing else to open, so it can be
  kept as a CI artifact or shared as is.
  """
  @spec to_html(Result.t() | [Result.t()]) :: String.t()
  def to_html(%Result{} = result), do: to_html([result])
  def to_html(results) when is_list(results), do: Stampede.Reporter.HTML.render(results)

  defp metrics([], []), do: "\n  no metrics were recorded\n"
  defp metrics([], _checks), do: []

  defp metrics(metrics, _checks) do
    header = ["metric", "count", "rate/s" | Enum.map(@timing_stats, &Atom.to_string/1)]

    rows =
      for {name, summary} <- Enum.sort(metrics) do
        [name, Integer.to_string(summary.count), decimal(summary.rate) | timing_cells(summary)]
      end

    ["\n" | table([header | rows])]
  end

  defp timing_cells(%{type: :timing} = summary) do
    Enum.map(@timing_stats, &milliseconds(Map.fetch!(summary, &1)))
  end

  defp timing_cells(_counter), do: []

  defp checks([]), do: []

  defp checks(checks) do
    lines =
      for {name, check} <- Enum.sort(checks) do
        passed = :erlang.float_to_binary(check.passed / check.count * 100, decimals: 1) <> "%"
        "    #{String.pad_leading(passed, 6)}  #{name} (#{check.passed} of #{check.count})\n"
      end

    ["\n  checks\n" | lines]
  end

  defp thresholds([]), do: []

  defp thresholds(thresholds) do
    lines =
      for threshold <- thresholds do
        status = if threshold.passed?, do: "pass", else: "FAIL"

        "    #{status}  #{threshold.metric} #{threshold.stat} <= " <>
          "#{stat(threshold.stat, threshold.limit)} (#{actual(threshold)})\n"
      end

    ["\n  thresholds\n" | lines]
  end

  defp errors([]), do: []

  defp errors(errors) do
    lines = for error <- Enum.take(errors, 5), do: "    #{error.count}x #{error.message}\n"
    ["\n  errors\n" | lines]
  end

  defp actual(%{value: nil}), do: "no samples"
  defp actual(%{stat: stat, value: value}), do: stat(stat, value)

  # Shared with the HTML report and mix stampede.compare.
  @doc false
  def stat(stat, value) when stat in [:count, :failed], do: to_string(value)
  def stat(:failed_rate, value), do: decimal(value)
  def stat(:rate, value), do: decimal(value) <> "/s"
  def stat(_timing, value), do: milliseconds(value)

  @doc false
  def table(rows) do
    widths =
      for row <- rows, {cell, index} <- Enum.with_index(row), reduce: %{} do
        widths -> Map.update(widths, index, String.length(cell), &max(&1, String.length(cell)))
      end

    for row <- rows do
      cells =
        for {cell, index} <- Enum.with_index(row) do
          if index == 0,
            do: String.pad_trailing(cell, widths[index]),
            else: String.pad_leading(cell, widths[index])
        end

      ["  ", Enum.join(cells, "  "), "\n"]
    end
  end

  @doc false
  def milliseconds(value) when value < 1, do: "#{round(value * 1000)}µs"
  def milliseconds(value) when value < 1000, do: decimal(value) <> "ms"
  def milliseconds(value), do: decimal(value / 1000) <> "s"

  @doc false
  def seconds(milliseconds), do: :erlang.float_to_binary(milliseconds / 1000, decimals: 1) <> "s"

  @doc false
  def decimal(number), do: :erlang.float_to_binary(number / 1, decimals: 2)
end
