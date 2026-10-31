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
      server(result.server),
      busy(busy_warning(result)),
      limit(result.limit),
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

  @doc """
  Returns a badge for a run with `:find_limit`, as an SVG image in the
  style of shields.io, saying how much load it held, such as "load tested |
  1,200 VUs".

      File.write!("loadtest/badge.svg", Stampede.Reporter.to_badge(result))

  Raises `ArgumentError` for a run without `:find_limit`.
  """
  @spec to_badge(Result.t()) :: String.t()
  def to_badge(%Result{limit: %{} = limit}) do
    value =
      case limit do
        %{value: nil, steps: [step | _]} -> "under " <> amount(step.target, limit.by)
        %{value: value, up_to?: true} -> amount(value, limit.by) <> "+"
        %{value: value} -> amount(value, limit.by)
      end

    right = value <> if(limit.by == :vus, do: " VUs", else: "/s")
    color = if limit.value, do: "#6b46a8", else: "#9f9f9f"
    Stampede.Reporter.Badge.render("load tested", right, color)
  end

  def to_badge(%Result{}) do
    raise ArgumentError, "expected the result of a run with :find_limit"
  end

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

  defp server(nil), do: []

  defp server(server) do
    queues =
      for %{length: length, process: process} <- server.queues do
        "      #{integer(length)}  #{process}\n"
      end

    [
      "\n  server\n    #{Enum.join(server.nodes, ", ")} at its busiest: schedulers ",
      "#{percent(server.busy)} busy, #{bytes(server.memory)} of memory, ",
      "#{integer(server.processes)} processes, run queue #{integer(server.run_queue)}\n",
      lost(server),
      if(queues != [], do: ["    longest message queues\n" | queues], else: [])
    ]
  end

  defp lost(%{lost: [_ | _] = lost}),
    do: "    went down during the run: #{Enum.join(lost, ", ")}\n"

  defp lost(_server), do: []

  # Shared with the HTML report.
  @doc false
  def bytes(bytes), do: "#{decimal(bytes / 1_000_000_000)} GB"

  defp busy(nil), do: []
  defp busy(warning), do: ["\n  warning\n    ", warning, "\n"]

  # Past this, the load test's own delays show up in its timings.
  @busy 0.9

  # Shared with the HTML report.
  @doc false
  def busy_warning(%Result{timeline: timeline}) do
    case for %{busy: busy} <- timeline, busy >= @busy, do: busy do
      [] ->
        nil

      busy ->
        "The load test was #{percent(Enum.max(busy))} busy at most, and 90% or more " <>
          "for #{length(busy)}s, so timings from then include its own delays. " <>
          "Spread the load over more machines to measure the server alone."
    end
  end

  defp percent(fraction), do: "#{round(fraction * 100)}%"

  defp limit(nil), do: []

  defp limit(limit) do
    columns =
      case limit.steps do
        [step | _] -> Enum.map(step.thresholds, &{&1.metric, &1.stat})
        [] -> []
      end

    header = [unit(limit.by) | Enum.map(columns, fn {metric, stat} -> "#{metric} #{stat}" end)]

    rows =
      for step <- limit.steps do
        values =
          for threshold <- step.thresholds do
            if threshold.value == nil,
              do: "no samples",
              else: stat(threshold.stat, threshold.value)
          end

        [amount(step.target, limit.by) | values] ++ [if(step.passed?, do: "pass", else: "FAIL")]
      end

    ["\n  limit\n    ", limit_headline(limit), "\n\n" | table([header ++ ["status"] | rows])]
  end

  # Shared with the HTML report.
  @doc false
  def limit_headline(limit) do
    unit = unit(limit.by)

    headline =
      cond do
        limit.value == nil ->
          step = limit.failed
          "Didn't hold the first step, #{amount(step.target, limit.by)} #{unit}: #{why(step)}"

        limit.up_to? ->
          "Held #{amount(limit.value, limit.by)} #{unit}, the most it was asked to try"

        true ->
          step = limit.failed

          "Held #{amount(limit.value, limit.by)} #{unit}. " <>
            "At #{amount(step.target, limit.by)} #{unit}, #{why(step)}"
      end

    headline =
      if limit.min && limit.value && limit.value < limit.min,
        do: headline <> ", under the minimum of #{amount(limit.min, limit.by)} #{unit}",
        else: headline

    case limit.failed do
      # Everything else that step can say comes from the server being gone.
      %{server_lost?: true} ->
        headline <> ". The server went down during that step"

      %{busy: busy} when busy >= @busy ->
        headline <>
          ". The load test was #{percent(busy)} busy at that step, so the limit may be " <>
          "its own rather than the server's"

      %{server_busy: busy} when busy >= @busy ->
        headline <> ". The server's schedulers were #{percent(busy)} busy at that step"

      _passed_or_not_busy ->
        headline
    end
  end

  defp why(step) do
    step.thresholds
    |> Enum.reject(& &1.passed?)
    |> Enum.map_join(" and ", fn threshold ->
      value =
        if threshold.value == nil,
          do: "had no samples",
          else: "was #{stat(threshold.stat, threshold.value)}"

      "#{threshold.metric} #{threshold.stat} #{value}, over #{stat(threshold.stat, threshold.limit)}"
    end)
  end

  defp unit(:vus), do: "VUs"
  defp unit(:rate), do: "iterations/s"

  @doc false
  def amount(value, :vus), do: integer(value)
  def amount(value, :rate) when value == trunc(value), do: integer(trunc(value))
  def amount(value, :rate), do: decimal(value)

  defp integer(number) do
    number
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/\d{3}(?=\d)/, "\\0,")
    |> String.reverse()
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
