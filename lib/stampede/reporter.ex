defmodule Stampede.Reporter do
  @moduledoc """
  Formats a `Stampede.Result` for the terminal.
  """

  alias Stampede.Result

  @timing_stats [:mean, :p50, :p90, :p95, :p99, :max]

  @doc """
  Returns a summary of `result`, with a line per metric followed by the
  thresholds and the most frequent errors, if there are any.
  """
  @spec format(Result.t()) :: String.t()
  def format(%Result{} = result) do
    IO.iodata_to_binary([
      "#{inspect(result.scenario)} ran for #{seconds(result.duration)}\n",
      metrics(result.metrics),
      thresholds(result.thresholds),
      errors(result.errors)
    ])
  end

  defp metrics(metrics) when map_size(metrics) == 0, do: "\n  no metrics were recorded\n"

  defp metrics(metrics) do
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

  defp stat(:count, value), do: to_string(value)
  defp stat(:rate, value), do: decimal(value) <> "/s"
  defp stat(_timing, value), do: milliseconds(value)

  defp table(rows) do
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

  defp milliseconds(value) when value < 1, do: "#{round(value * 1000)}µs"
  defp milliseconds(value) when value < 1000, do: decimal(value) <> "ms"
  defp milliseconds(value), do: decimal(value / 1000) <> "s"

  defp seconds(milliseconds), do: :erlang.float_to_binary(milliseconds / 1000, decimals: 1) <> "s"

  defp decimal(number), do: :erlang.float_to_binary(number / 1, decimals: 2)
end
