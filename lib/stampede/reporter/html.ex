defmodule Stampede.Reporter.HTML do
  @moduledoc false

  # One self-contained page per report: the charts are inline SVG and the
  # tooltips a short script, so the file opens anywhere and can be shared.
  # Stampede.Dashboard renders its page with the same parts.

  import Stampede.Reporter,
    only: [
      amount: 2,
      busy_warning: 1,
      decimal: 1,
      limit_headline: 1,
      milliseconds: 1,
      seconds: 1,
      stat: 2
    ]

  alias Stampede.Result

  @width 360
  @height 180
  @left 44
  @right 12
  @top 12
  @bottom 24

  @timing_stats [:mean, :p50, :p90, :p95, :p99, :max]
  @percentiles [p50: 1, p95: 2, p99: 3]
  @steps [100, 200, 500, 1_000, 2_000, 5_000, 10_000, 15_000, 30_000, 60_000, 120_000] ++
           [300_000, 600_000, 900_000, 1_800_000, 3_600_000, 7_200_000]

  @css """
  :root {
    color-scheme: light;
    --page: #f9f9f7;
    --surface: #fcfcfb;
    --ink: #0b0b0b;
    --ink-2: #52514e;
    --muted: #898781;
    --grid: #e1e0d9;
    --axis: #c3c2b7;
    --border: rgba(11, 11, 11, 0.1);
    --series-1: #2a78d6;
    --series-2: #eb6834;
    --series-3: #1baf7a;
    --good: #0ca30c;
    --critical: #d03b3b;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      color-scheme: dark;
      --page: #0d0d0d;
      --surface: #1a1a19;
      --ink: #f0efec;
      --ink-2: #c3c2b7;
      --grid: #2c2c2a;
      --axis: #383835;
      --border: rgba(255, 255, 255, 0.1);
      --series-1: #3987e5;
      --series-2: #d95926;
      --series-3: #199e70;
    }
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    background: var(--page);
    color: var(--ink);
    font: 14px/1.5 system-ui, -apple-system, "Segoe UI", sans-serif;
  }
  main { max-width: 72rem; margin: 0 auto; padding: 24px 16px 48px; }
  h1 { font-size: 20px; margin: 0 0 8px; }
  h2 { font-size: 18px; margin: 0; overflow-wrap: anywhere; }
  h3 { font-size: 14px; margin: 24px 0 8px; }
  section { margin-top: 32px; }
  header { display: flex; flex-wrap: wrap; align-items: baseline; gap: 4px 12px; }
  .meta, figcaption, summary { color: var(--ink-2); }
  .meta { margin: 0; }
  .status { font-weight: 600; }
  .status::before { margin-right: 4px; }
  .passed::before { content: "\\2713"; color: var(--good); }
  .failed::before { content: "\\2717"; color: var(--critical); }
  .running::before { content: "\\25CF"; color: var(--series-1); }
  .notice {
    padding: 8px 12px;
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 8px;
  }
  .tiles, .charts { display: grid; gap: 12px; margin-top: 16px; }
  .tiles { grid-template-columns: repeat(auto-fill, minmax(10rem, 1fr)); }
  .charts { grid-template-columns: repeat(auto-fill, minmax(min(100%, 22rem), 1fr)); }
  .tile, .chart, .table {
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 8px;
  }
  .tile { padding: 12px; }
  .tile span { display: block; color: var(--ink-2); font-size: 12px; }
  .tile strong { font-size: 22px; font-weight: 600; }
  .chart { position: relative; margin: 0; padding: 12px; outline-offset: 2px; }
  figcaption { display: flex; flex-wrap: wrap; gap: 4px 12px; font-size: 13px; }
  figcaption b { color: var(--ink); font-weight: 600; margin-right: auto; overflow-wrap: anywhere; }
  .key { display: inline-block; width: 12px; height: 2px; margin-right: 4px; vertical-align: middle; }
  .k1 { background: var(--series-1); }
  .k2 { background: var(--series-2); }
  .k3 { background: var(--series-3); }
  svg { display: block; width: 100%; height: auto; margin-top: 8px; overflow: visible; }
  svg text { fill: var(--muted); font-size: 11px; font-variant-numeric: tabular-nums; }
  svg line, svg path, svg circle { vector-effect: non-scaling-stroke; }
  .grid { stroke: var(--grid); }
  .axis { stroke: var(--axis); }
  .cross { stroke: var(--muted); display: none; }
  .line { fill: none; stroke-width: 2; stroke-linejoin: round; stroke-linecap: round; }
  .line.s1 { stroke: var(--series-1); }
  .line.s2 { stroke: var(--series-2); }
  .line.s3 { stroke: var(--series-3); }
  .dot { stroke: var(--surface); stroke-width: 2; }
  .dot.s1 { fill: var(--series-1); }
  .dot.s2 { fill: var(--series-2); }
  .dot.s3 { fill: var(--series-3); }
  .tip {
    position: absolute;
    top: 40px;
    min-width: 8rem;
    padding: 8px 10px;
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 6px;
    box-shadow: 0 4px 12px rgba(0, 0, 0, 0.12);
    font-size: 12px;
    pointer-events: none;
  }
  .tip div { white-space: nowrap; }
  .tip .at { color: var(--ink-2); margin-bottom: 2px; }
  .tip strong { font-variant-numeric: tabular-nums; margin-right: 6px; }
  .tip span:last-child { color: var(--ink-2); }
  .table { overflow-x: auto; }
  table { border-collapse: collapse; width: 100%; font-variant-numeric: tabular-nums; }
  th, td { padding: 6px 12px; text-align: right; white-space: nowrap; }
  th { color: var(--ink-2); font-weight: 500; }
  th:first-child, td:first-child { text-align: left; }
  td:first-child { white-space: normal; overflow-wrap: anywhere; }
  tr + tr td, thead + tbody td { border-top: 1px solid var(--grid); }
  details { margin-top: 16px; }
  summary { cursor: pointer; }
  details .table { margin-top: 8px; max-height: 24rem; overflow-y: auto; }
  pre { margin: 0; white-space: pre-wrap; overflow-wrap: anywhere; font-size: 12px; }
  .errors td { vertical-align: top; text-align: left; }
  """

  @js """
  const setupCharts = (root) => {
  for (const chart of root.querySelectorAll(".chart")) {
    const data = JSON.parse(chart.dataset.points);
    const svg = chart.querySelector("svg");
    const cross = chart.querySelector(".cross");
    const tip = chart.querySelector(".tip");
    let index = null;

    const show = (i) => {
      index = i;
      cross.setAttribute("x1", data.x[i]);
      cross.setAttribute("x2", data.x[i]);
      cross.style.display = "block";

      const at = document.createElement("div");
      at.className = "at";
      at.textContent = data.at[i];
      tip.replaceChildren(at);

      for (const series of data.series) {
        const row = document.createElement("div");
        const key = document.createElement("span");
        const value = document.createElement("strong");
        const name = document.createElement("span");
        key.className = "key k" + series.slot;
        value.textContent = series.values[i] ?? "\\u2013";
        name.textContent = series.name;
        row.append(key, value, name);
        tip.append(row);
      }

      tip.hidden = false;
      const x = svg.offsetLeft + (data.x[i] / data.width) * svg.clientWidth;
      const right = x + 12 + tip.offsetWidth <= chart.clientWidth;
      tip.style.left = Math.max(right ? x + 12 : x - 12 - tip.offsetWidth, 0) + "px";
    };

    const hide = () => {
      index = null;
      cross.style.display = "none";
      tip.hidden = true;
    };

    svg.addEventListener("pointermove", (event) => {
      const box = svg.getBoundingClientRect();
      const x = ((event.clientX - box.left) / box.width) * data.width;
      let nearest = 0;
      data.x.forEach((point, i) => {
        if (Math.abs(point - x) < Math.abs(data.x[nearest] - x)) nearest = i;
      });
      show(nearest);
    });

    svg.addEventListener("pointerleave", hide);
    chart.addEventListener("blur", hide);
    chart.addEventListener("keydown", (event) => {
      const last = data.x.length - 1;
      if (event.key === "ArrowLeft") show(index === null ? last : Math.max(index - 1, 0));
      else if (event.key === "ArrowRight") show(index === null ? 0 : Math.min(index + 1, last));
      else if (event.key === "Escape") hide();
      else return;
      event.preventDefault();
    });
  }
  };

  setupCharts(document);
  """

  # The dashboard asks for its runs every second, with the version it has,
  # and gets them back only when they changed.
  @poll_js """
  const runs = document.getElementById("runs");

  const poll = async () => {
    try {
      const response = await fetch("runs?version=" + runs.dataset.version, { cache: "no-store" });

      if (response.status === 200) {
        const open = [...runs.querySelectorAll("details[open]")].map((details) => details.closest("section").id);
        runs.dataset.version = response.headers.get("x-version");
        runs.innerHTML = await response.text();
        for (const id of open) runs.querySelector("#" + id + " details")?.setAttribute("open", "");
        setupCharts(runs);
      }

      setTimeout(poll, 1000);
    } catch (_error) {
      document.getElementById("stopped").hidden = false;
    }
  };

  setTimeout(poll, 1000);
  """

  def render(results) do
    document("Stampede report", Enum.map(results, &scenario(&1, nil)), [])
  end

  # The dashboard's page, with the runs it knows of at `version`.
  def dashboard(runs, version) do
    body = [
      ~s(<p class="meta notice" id="stopped" hidden>),
      "The dashboard stopped, so this page no longer updates.</p>\n",
      ~s(<div id="runs" data-version="#{version}">\n),
      runs(runs),
      "</div>\n"
    ]

    document("Stampede dashboard", body, @poll_js)
  end

  # Each run is a map with an `:id`, its `:scenario` and `:status`, and
  # either its `:result` once it is over, or what the dashboard collected so
  # far: its `:timeline`, the last `:summaries` of every metric, the `:totals`
  # of their counts, and how long it is `:planned` to last.
  def runs([]), do: ~s(<p class="meta">Waiting for a run to start.</p>\n)
  def runs(runs), do: Enum.map(runs, &run/1)

  defp run(%{result: %Result{} = result} = run), do: scenario(result, run.id)
  defp run(run), do: live(run)

  defp document(title, body, script) do
    IO.iodata_to_binary([
      ~s(<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n),
      ~s(<meta name="viewport" content="width=device-width, initial-scale=1">\n),
      "<title>",
      title,
      "</title>\n<style>\n",
      @css,
      "</style>\n</head>\n<body>\n<main>\n<h1>",
      title,
      "</h1>\n",
      body,
      "</main>\n<script>\n",
      @js,
      script,
      "</script>\n</body>\n</html>\n"
    ])
  end

  defp live(run) do
    last = List.last(run.timeline)
    at = if last, do: last.at, else: 0

    result = %Result{
      scenario: run.scenario,
      duration: max(run.planned, at),
      timeline: run.timeline
    }

    status =
      case run.status do
        :running -> ~s(<span class="status running">Running</span>)
        :stopped -> ~s(<span class="status failed">Stopped</span>)
      end

    [
      section_start(run.id, run.scenario, status),
      seconds(at),
      " of ",
      seconds(run.planned),
      "</p></header>\n",
      live_tiles(run, last),
      if(last,
        do: charts(%{result | metrics: run.summaries}),
        else: ~s(<p class="meta">Starting.</p>\n)
      ),
      if(last && last.metrics != %{},
        do: ["<h3>The last second</h3>\n", metrics_table(last.metrics)],
        else: []
      ),
      "</section>\n"
    ]
  end

  defp live_tiles(run, last) do
    metrics = if last, do: last.metrics, else: %{}
    iteration = metrics["iteration"]

    tiles = [
      {"VUs", integer(if last, do: last.vus, else: 0)},
      {"Iterations", integer(Map.get(run.totals, "iteration", 0))},
      {"Iterations per second", decimal(if iteration, do: iteration.rate, else: 0)},
      {"Iteration p95", if(iteration, do: milliseconds(iteration.p95), else: "–")},
      {"Errors", integer(Map.get(run.totals, "iteration.errors", 0))}
    ]

    tile_grid(tiles)
  end

  defp section_start(id, scenario, status) do
    [
      if(id, do: ~s(<section id="run-#{id}">\n<header><h2>), else: "<section>\n<header><h2>"),
      escape(inspect(scenario)),
      "</h2>",
      status,
      ~s(<p class="meta">)
    ]
  end

  defp scenario(%Result{} = result, id) do
    {checks, metrics} = Enum.split_with(result.metrics, &match?({_name, %{type: :check}}, &1))

    [
      section_start(id, result.scenario, status(result)),
      "Ran for ",
      seconds(result.duration),
      downloads(id),
      "</p></header>\n",
      result_tiles(result),
      busy(busy_warning(result)),
      limit(result.limit),
      charts(result),
      metrics(metrics),
      checks(checks),
      thresholds(result.thresholds),
      errors(result.errors),
      timeline(result),
      "</section>\n"
    ]
  end

  defp status(%Result{thresholds: []}), do: []
  defp status(%Result{passed?: true}), do: ~s(<span class="status passed">Passed</span>)
  defp status(%Result{passed?: false}), do: ~s(<span class="status failed">Failed</span>)

  defp result_tiles(result) do
    metrics = result.metrics
    iteration = metrics["iteration"]

    limit =
      case result.limit do
        %{value: nil} -> [{"Limit", "none"}]
        %{value: value, by: by, up_to?: up_to?} -> [{"Limit", limit_tile(value, by, up_to?)}]
        nil -> []
      end

    tiles =
      limit ++
        [
          {"Iterations", integer(count(metrics, "iteration"))},
          {"Iterations per second", decimal(if iteration, do: iteration.rate, else: 0)},
          {"Iteration p95", if(iteration, do: milliseconds(iteration.p95), else: "–")},
          {"Errors", integer(count(metrics, "iteration.errors"))},
          {"Peak VUs", integer(result.timeline |> Enum.map(& &1.vus) |> Enum.max(fn -> 0 end))}
        ] ++
        if metrics["iterations.dropped"],
          do: [{"Dropped", integer(count(metrics, "iterations.dropped"))}],
          else: []

    tile_grid(tiles)
  end

  # On the dashboard, finished runs can be saved as the report and the JSON.
  defp downloads(nil), do: []

  defp downloads(id) do
    [
      ~s( · <a href="runs/#{id}/report.html" download>HTML report</a>),
      ~s( · <a href="runs/#{id}/results.json" download>JSON</a>)
    ]
  end

  defp limit_tile(value, by, up_to?) do
    plus = if up_to?, do: "+", else: ""
    unit = if by == :vus, do: " VUs", else: "/s"
    amount(value, by) <> plus <> unit
  end

  defp busy(nil), do: []

  defp busy(warning),
    do: [~s(<p class="meta"><strong>Warning:</strong> ), escape(warning), "</p>\n"]

  defp limit(nil), do: []

  defp limit(limit) do
    thresholds =
      case limit.steps do
        [step | _] -> step.thresholds
        [] -> []
      end

    header =
      [if(limit.by == :vus, do: "VUs", else: "iterations/s")] ++
        Enum.map(thresholds, &escape("#{&1.metric} #{&1.stat}")) ++ ["status"]

    rows =
      for step <- limit.steps do
        values =
          for threshold <- step.thresholds do
            if threshold.value == nil,
              do: "no samples",
              else: stat(threshold.stat, threshold.value)
          end

        status =
          if step.passed?,
            do: ~s(<span class="status passed">held</span>),
            else: ~s(<span class="status failed">over</span>)

        [amount(step.target, limit.by) | values] ++ [status]
      end

    [
      ~s(<h3>Limit</h3>\n<p class="meta">),
      escape(limit_headline(limit)),
      ".</p>\n",
      table(header, rows)
    ]
  end

  defp tile_grid(tiles) do
    [
      ~s(<div class="tiles">\n),
      for {label, value} <- tiles do
        [~s(<div class="tile"><span>), label, "</span><strong>", value, "</strong></div>\n"]
      end,
      "</div>\n"
    ]
  end

  defp charts(%Result{timeline: []}), do: []

  defp charts(result) do
    %{timeline: timeline, metrics: metrics} = result

    iterations =
      for {name, label, slot} <- [
            {"iteration", "iterations", 1},
            {"iteration.errors", "errors", 2},
            {"iterations.dropped", "dropped", 3}
          ],
          name == "iteration" or Map.has_key?(metrics, name) do
        {label, slot, Enum.map(timeline, &(get_in(&1.metrics, [name, :rate]) || 0))}
      end

    timings = for {name, %{type: :timing}} <- Enum.sort(metrics), do: name

    latencies =
      for name <- Enum.sort_by(timings, &(&1 != "iteration")) do
        series =
          for {stat, slot} <- @percentiles do
            {Atom.to_string(stat), slot, Enum.map(timeline, &get_in(&1.metrics, [name, stat]))}
          end

        chart(name, result, series, :ms)
      end

    [
      ~s(<div class="charts">\n),
      chart("VUs", result, [{"VUs", 1, Enum.map(timeline, & &1.vus)}], :count),
      chart("Iterations per second", result, iterations, :rate),
      latencies,
      "</div>\n"
    ]
  end

  defp chart(title, result, series, unit) do
    xs = Enum.map(result.timeline, &x(&1.at, result.duration))

    max =
      series
      |> Enum.flat_map(&elem(&1, 2))
      |> Enum.reject(&is_nil/1)
      |> Enum.max(fn -> 0 end)

    {top, ticks} = y_ticks(max, unit)
    y = fn value -> @top + (1 - value / top) * (@height - @top - @bottom) end

    data = %{
      width: @width,
      x: Enum.map(xs, &round1/1),
      at: Enum.map(result.timeline, &seconds(&1.at)),
      series:
        for {name, slot, values} <- series do
          %{name: name, slot: slot, values: Enum.map(values, &value(&1, unit))}
        end
    }

    [
      ~s(<figure class="chart" tabindex="0" data-points="),
      escape(JSON.encode!(data)),
      ~s(">\n<figcaption><b>),
      escape(title),
      "</b>",
      legend(series),
      "</figcaption>\n",
      ~s(<svg viewBox="0 0 #{@width} #{@height}" role="img" aria-label="),
      escape(title),
      ~s(">\n),
      y_axis(ticks, y, unit),
      x_axis(result.duration),
      Enum.map(series, &series(&1, xs, y)),
      ~s(<line class="cross" y1="#{@top}" y2="#{@height - @bottom}"/>\n),
      ~s(</svg>\n<div class="tip" hidden></div>\n</figure>\n)
    ]
  end

  defp legend([_single]), do: []

  defp legend(series) do
    for {name, slot, _values} <- series do
      [~s(<span><i class="key k#{slot}"></i>), escape(name), "</span>"]
    end
  end

  defp y_axis(ticks, y, unit) do
    for tick <- ticks do
      position = round1(y.(tick))
      class = if tick == 0, do: "axis", else: "grid"

      [
        ~s(<line class="#{class}" x1="#{@left}" x2="#{@width - @right}" ),
        ~s(y1="#{position}" y2="#{position}"/>),
        ~s(<text x="#{@left - 6}" y="#{position}" dy="0.32em" text-anchor="end">),
        tick(tick, unit),
        "</text>\n"
      ]
    end
  end

  defp x_axis(duration) do
    step = Enum.find(@steps, List.last(@steps), &(duration / &1 <= 6))

    for at <- 0..duration//step do
      ~s(<text x="#{round1(x(at, duration))}" y="#{@height - 6}" text-anchor="middle">) <>
        "#{time(at)}</text>\n"
    end
  end

  # Samples are left out of seconds that had none, which breaks the line.
  defp series({_name, slot, values}, xs, y) do
    xs
    |> Enum.zip(values)
    |> Enum.chunk_by(&is_nil(elem(&1, 1)))
    |> Enum.reject(fn [{_x, value} | _rest] -> is_nil(value) end)
    |> Enum.map(fn
      [{x, value}] ->
        ~s(<circle class="dot s#{slot}" cx="#{round1(x)}" cy="#{round1(y.(value))}" r="5"/>\n)

      points ->
        path =
          Enum.map_intersperse(points, " L", fn {x, value} ->
            "#{round1(x)},#{round1(y.(value))}"
          end)

        [~s(<path class="line s#{slot}" d="M), path, ~s("/>\n)]
    end)
  end

  defp x(at, duration), do: @left + at / max(duration, 1) * (@width - @left - @right)

  defp y_ticks(max, unit) do
    raw = max(max, if(unit == :ms, do: 0.001, else: 1)) / 4
    magnitude = :math.pow(10, floor(:math.log10(raw)))
    factors = if unit == :count, do: [1, 2, 5, 10], else: [1, 2, 2.5, 5, 10]
    step = Enum.find(factors, &(&1 * magnitude >= raw)) * magnitude
    step = if unit == :count, do: max(round(step), 1), else: step
    count = max(ceil(max / step), 1)
    {step * count, for(index <- 0..count, do: step * index)}
  end

  defp tick(value, _unit) when value == 0, do: "0"
  defp tick(value, :ms) when value < 1, do: "#{round(value * 1000)}µs"
  defp tick(value, :ms) when value < 1000, do: short(value) <> "ms"
  defp tick(value, :ms), do: short(value / 1000) <> "s"
  defp tick(value, _unit) when value >= 1_000_000, do: short(value / 1_000_000) <> "M"
  defp tick(value, _unit) when value >= 1000, do: short(value / 1000) <> "K"
  defp tick(value, _unit), do: short(value)

  defp value(nil, _unit), do: nil
  defp value(value, :ms), do: milliseconds(value)
  defp value(value, :count), do: integer(value)
  defp value(value, :rate), do: decimal(value) <> "/s"

  defp metrics([]), do: []
  defp metrics(metrics), do: ["<h3>Metrics</h3>\n", metrics_table(metrics)]

  defp metrics_table(metrics) do
    header = ["metric", "count", "rate/s" | Enum.map(@timing_stats, &Atom.to_string/1)]

    rows =
      for {name, summary} <- Enum.sort(metrics) do
        timings =
          if summary.type == :timing,
            do: Enum.map(@timing_stats, &milliseconds(Map.fetch!(summary, &1))),
            else: List.duplicate("", length(@timing_stats))

        [escape(name), integer(summary.count), decimal(summary.rate) | timings]
      end

    table(header, rows)
  end

  defp checks([]), do: []

  defp checks(checks) do
    rows =
      for {name, check} <- Enum.sort(checks) do
        passed = :erlang.float_to_binary(check.passed / check.count * 100, decimals: 1) <> "%"
        [escape(name), passed, integer(check.passed), integer(check.failed)]
      end

    ["<h3>Checks</h3>\n", table(["check", "passed", "passes", "fails"], rows)]
  end

  defp thresholds([]), do: []

  defp thresholds(thresholds) do
    rows =
      for threshold <- thresholds do
        status =
          if threshold.passed?,
            do: ~s(<span class="status passed">pass</span>),
            else: ~s(<span class="status failed">fail</span>)

        [
          escape(threshold.metric),
          Atom.to_string(threshold.stat),
          stat(threshold.stat, threshold.limit),
          if(threshold.value == nil,
            do: "no samples",
            else: stat(threshold.stat, threshold.value)
          ),
          status
        ]
      end

    ["<h3>Thresholds</h3>\n", table(["metric", "stat", "limit", "value", "status"], rows)]
  end

  defp errors([]), do: []

  defp errors(errors) do
    rows =
      for error <- Enum.take(errors, 10) do
        [~s(<td>#{integer(error.count)}x</td><td><pre>), escape(error.message), "</pre></td>"]
      end

    [
      ~s(<h3>Errors</h3>\n<div class="table errors"><table><tbody>\n),
      Enum.map(rows, &["<tr>", &1, "</tr>\n"]),
      "</tbody></table></div>\n"
    ]
  end

  # The timeline as a table, for what the charts show in color alone.
  defp timeline(%Result{timeline: []}), do: []

  defp timeline(result) do
    timings = for {name, %{type: :timing}} <- Enum.sort(result.metrics), do: name
    header = ["time", "VUs", "iterations/s", "errors/s" | Enum.map(timings, &"#{escape(&1)} p95")]

    rows =
      for point <- result.timeline do
        [
          seconds(point.at),
          integer(point.vus),
          decimal(get_in(point.metrics, ["iteration", :rate]) || 0),
          decimal(get_in(point.metrics, ["iteration.errors", :rate]) || 0)
          | Enum.map(timings, &(value(get_in(point.metrics, [&1, :p95]), :ms) || "–"))
        ]
      end

    ["<details><summary>Timeline</summary>\n", table(header, rows), "</details>\n"]
  end

  defp table(header, rows) do
    [
      ~s(<div class="table"><table>\n<thead><tr>),
      Enum.map(header, &["<th>", &1, "</th>"]),
      "</tr></thead>\n<tbody>\n",
      Enum.map(rows, fn row -> ["<tr>", Enum.map(row, &["<td>", &1, "</td>"]), "</tr>\n"] end),
      "</tbody></table></div>\n"
    ]
  end

  defp count(metrics, name) do
    case metrics[name] do
      %{count: count} -> count
      nil -> 0
    end
  end

  defp time(milliseconds) when milliseconds < 1000 and milliseconds > 0, do: "#{milliseconds}ms"
  defp time(milliseconds) when milliseconds < 60_000, do: "#{div(milliseconds, 1000)}s"

  defp time(milliseconds) do
    minutes = div(milliseconds, 60_000)
    seconds = div(rem(milliseconds, 60_000), 1000)
    if seconds == 0, do: "#{minutes}m", else: "#{minutes}m#{seconds}s"
  end

  defp integer(number) do
    number
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/\d{3}(?=\d)/, "\\0,")
    |> String.reverse()
  end

  defp short(number) do
    rounded = Float.round(number / 1, 2)
    if rounded == trunc(rounded), do: Integer.to_string(trunc(rounded)), else: "#{rounded}"
  end

  defp round1(number), do: Float.round(number / 1, 1)

  defp escape(string) do
    for <<char <- string>>, into: "" do
      case char do
        ?& -> "&amp;"
        ?< -> "&lt;"
        ?> -> "&gt;"
        ?" -> "&quot;"
        ?' -> "&#39;"
        char -> <<char>>
      end
    end
  end
end
