defmodule Stampede.Reporter.HTML do
  @moduledoc false

  # One self-contained page per report: the charts are inline SVG and the
  # tooltips a short script, so the file opens anywhere and can be shared.
  # Stampede.Dashboard renders its page with the same parts, and so do the
  # LiveDashboard page and Livebook, which embed them.

  import Stampede.Reporter,
    only: [
      amount: 2,
      busy_warning: 1,
      bytes: 1,
      decimal: 1,
      limit_headline: 1,
      milliseconds: 1,
      seconds: 1,
      stat: 2
    ]

  alias Stampede.Result

  # Charts are drawn in these units and scale to their box.
  # Charts are drawn at the size of their slot, so their text stays the
  # same size: three to a row, two to a row, or a row of their own.
  @sizes %{third: {360, 180}, half: {540, 210}, wide: {1100, 260}}
  @left 44
  @right 12
  @top 14
  @bottom 24

  @timing_stats [:mean, :p50, :p90, :p95, :p99, :max]
  @percentiles [p50: 1, p95: 2, p99: 3]
  @steps [100, 200, 500, 1_000, 2_000, 5_000, 10_000, 15_000, 30_000, 60_000, 120_000] ++
           [300_000, 600_000, 900_000, 1_800_000, 3_600_000, 7_200_000]

  # The timing a run is judged by when no threshold says, most specific first.
  @main_metrics ~w(channel.join live.join http.request ws.connect llm.ttft iteration)

  # What a run that holds connections counts instead of finished iterations.
  @message_counters ~w(channel.messages ws.messages)

  @light """
    --page: #f5f6f8;
    --surface: #ffffff;
    --surface-2: #f8f9fb;
    --ink: #0f1419;
    --ink-2: #4b5563;
    --muted: #8a93a0;
    --grid: #e7eaee;
    --axis: #c9ced6;
    --border: #e3e6eb;
    --series-1: #2f6fde;
    --series-2: #e8590c;
    --series-3: #12a37b;
    --good: #138a4e;
    --good-soft: #e6f4ec;
    --critical: #c93636;
    --critical-soft: #fbeaea;
    --info-soft: #e9f0fc;
    --band-held: rgba(19, 138, 78, 0.07);
    --band-over: rgba(201, 54, 54, 0.09);
    --shadow: 0 1px 2px rgba(16, 24, 40, 0.04), 0 1px 3px rgba(16, 24, 40, 0.06);
  """

  # Everything but the page itself, so the same parts can be shown inside
  # another page, such as Phoenix LiveDashboard's. No rule in here may nest
  # braces, as embedding scopes each one.
  @parts """
  h2 { font-size: 20px; line-height: 1.25; margin: 0; font-weight: 650; letter-spacing: -0.01em; overflow-wrap: anywhere; }
  h3 { font-size: 11px; font-weight: 650; letter-spacing: 0.08em; text-transform: uppercase; color: var(--ink-2); margin: 28px 0 10px; }
  section { margin-top: 24px; background: var(--surface); border: 1px solid var(--border); border-radius: 14px; padding: 20px 22px 24px; box-shadow: var(--shadow); }
  section > header { display: flex; flex-wrap: wrap; align-items: center; gap: 6px 12px; }
  .meta, figcaption, summary { color: var(--ink-2); }
  .meta { margin: 0; }
  section > header .meta { flex-basis: 100%; font-size: 13px; }
  a { color: var(--series-1); }
  .status { display: inline-flex; align-items: center; gap: 6px; font-size: 12px; font-weight: 600; line-height: 1; padding: 5px 10px 5px 8px; border-radius: 999px; background: var(--info-soft); color: var(--series-1); }
  .status::before { content: ""; width: 7px; height: 7px; border-radius: 50%; background: currentColor; }
  .passed { background: var(--good-soft); color: var(--good); }
  .failed { background: var(--critical-soft); color: var(--critical); }
  .running::before { animation: stampede-pulse 1.4s ease-in-out infinite; }
  td .status { font-size: 11px; padding: 4px 8px 4px 7px; }
  .progress { flex-basis: 100%; height: 4px; border-radius: 999px; background: var(--grid); overflow: hidden; margin-top: 4px; }
  .progress span { display: block; height: 100%; border-radius: 999px; background: var(--series-1); }
  .notice { padding: 10px 14px; background: var(--surface); border: 1px solid var(--border); border-radius: 10px; }
  .verdict { margin-top: 18px; padding: 14px 16px; border-radius: 12px; background: var(--good-soft); border: 1px solid transparent; }
  .verdict.over { background: var(--critical-soft); }
  .verdict strong { display: block; font-size: 17px; font-weight: 650; color: var(--good); margin-bottom: 2px; }
  .verdict.over strong { color: var(--critical); }
  .verdict p { margin: 0; color: var(--ink); }
  .warning { margin-top: 14px; padding: 10px 14px; border-radius: 10px; background: var(--critical-soft); color: var(--ink); }
  .tiles, .charts { display: grid; gap: 12px; margin-top: 16px; }
  .tiles { grid-template-columns: repeat(auto-fill, minmax(10.5rem, 1fr)); }
  .charts { grid-template-columns: repeat(auto-fill, minmax(min(100%, 22rem), 1fr)); }
  .tile, .chart, .table-wrap { background: var(--surface); border: 1px solid var(--border); border-radius: 12px; }
  .tile { padding: 12px 14px; display: flex; flex-direction: column; gap: 4px; min-width: 0; }
  .tile span { color: var(--ink-2); font-size: 11px; font-weight: 600; letter-spacing: 0.06em; text-transform: uppercase; }
  .tile strong { font-size: 22px; line-height: 1.2; font-weight: 650; letter-spacing: -0.01em; font-variant-numeric: tabular-nums; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .tile small { color: var(--muted); font-size: 12px; overflow-wrap: anywhere; }
  .tile.bad strong { color: var(--critical); }
  .tile.good strong { color: var(--good); }
  .chart { position: relative; margin: 0; padding: 14px 14px 10px; outline-offset: 2px; min-width: 0; }
  .charts.pairs { grid-template-columns: repeat(auto-fill, minmax(min(100%, 30rem), 1fr)); }
  .chart.wide { grid-column: 1 / -1; }
  figcaption { display: flex; flex-wrap: wrap; align-items: center; gap: 4px 14px; font-size: 12px; }
  figcaption b { color: var(--ink); font-size: 13px; font-weight: 600; margin-right: auto; overflow-wrap: anywhere; }
  .key { display: inline-block; width: 10px; height: 10px; border-radius: 3px; margin-right: 5px; vertical-align: -1px; }
  .k1 { background: var(--series-1); }
  .k2 { background: var(--series-2); }
  .k3 { background: var(--series-3); }
  svg { display: block; width: 100%; height: auto; margin-top: 10px; overflow: visible; }
  svg text { fill: var(--muted); font-size: 11px; font-variant-numeric: tabular-nums; }
  svg line, svg path, svg circle, svg rect { vector-effect: non-scaling-stroke; }
  .grid { stroke: var(--grid); }
  .axis { stroke: var(--axis); }
  .cross { stroke: var(--muted); stroke-dasharray: 3 3; display: none; }
  .band.held { fill: var(--band-held); }
  .band.over { fill: var(--band-over); }
  .band-label { font-size: 10px; font-weight: 600; }
  .band-label.held { fill: var(--good); }
  .band-label.over { fill: var(--critical); }
  .limit { stroke: var(--critical); stroke-width: 1.25; stroke-dasharray: 5 4; opacity: 0.8; }
  .limit-label { fill: var(--critical); font-size: 10px; font-weight: 600; }
  .area { stroke: none; opacity: 0.12; }
  .area.s1 { fill: var(--series-1); }
  .line { fill: none; stroke-width: 2; stroke-linejoin: round; stroke-linecap: round; }
  .line.s1 { stroke: var(--series-1); }
  .line.s2 { stroke: var(--series-2); }
  .line.s3 { stroke: var(--series-3); }
  .dot { stroke: var(--surface); stroke-width: 2; }
  .dot.s1 { fill: var(--series-1); }
  .dot.s2 { fill: var(--series-2); }
  .dot.s3 { fill: var(--series-3); }
  .tip { position: absolute; top: 44px; min-width: 8rem; padding: 8px 10px; background: var(--surface); border: 1px solid var(--border); border-radius: 8px; box-shadow: 0 6px 20px rgba(16, 24, 40, 0.12); font-size: 12px; pointer-events: none; z-index: 2; }
  .tip div { white-space: nowrap; }
  .tip .at { color: var(--ink-2); margin-bottom: 2px; }
  .tip strong { font-variant-numeric: tabular-nums; margin-right: 6px; }
  .tip span:last-child { color: var(--ink-2); }
  .table-wrap { overflow-x: auto; }
  table { border-collapse: collapse; width: 100%; font-variant-numeric: tabular-nums; font-size: 13px; }
  th, td { padding: 8px 12px; text-align: right; white-space: nowrap; }
  th { color: var(--ink-2); font-size: 11px; font-weight: 600; letter-spacing: 0.05em; text-transform: uppercase; background: var(--surface-2); }
  th:first-child, td:first-child { text-align: left; }
  td:first-child { white-space: normal; overflow-wrap: anywhere; }
  tr + tr td, thead + tbody td { border-top: 1px solid var(--grid); }
  details { margin-top: 18px; }
  summary { cursor: pointer; font-weight: 600; font-size: 13px; }
  details .table-wrap { margin-top: 10px; max-height: 24rem; overflow-y: auto; }
  pre { margin: 0; white-space: pre-wrap; overflow-wrap: anywhere; font-size: 12px; }
  .errors td { vertical-align: top; text-align: left; }
  .queues { margin-top: 12px; font-size: 13px; }
  """

  # Rules that nest, kept out of the parts so embedding can scope those.
  @motion """
  @keyframes stampede-pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.35; } }
  @media (prefers-reduced-motion: reduce) { .running::before { animation: none; } }
  """

  @css """
       :root {
         color-scheme: light;
       #{@light}}
       * { box-sizing: border-box; }
       body {
         margin: 0;
         background: var(--page);
         color: var(--ink);
         font: 14px/1.5 system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", sans-serif;
         -webkit-font-smoothing: antialiased;
       }
       .topbar { border-bottom: 1px solid var(--border); background: var(--surface); }
       .topbar div { max-width: 76rem; margin: 0 auto; padding: 12px 20px; display: flex; align-items: center; gap: 10px; }
       .brand { font-weight: 700; font-size: 15px; letter-spacing: -0.01em; }
       h1 { font-size: 13px; font-weight: 500; color: var(--ink-2); margin: 0; padding-left: 10px; border-left: 1px solid var(--border); }
       .live { margin-left: auto; font-size: 12px; color: var(--ink-2); display: inline-flex; align-items: center; gap: 6px; }
       .live::before { content: ""; width: 7px; height: 7px; border-radius: 50%; background: var(--good); }
       main { max-width: 76rem; margin: 0 auto; padding: 8px 20px 56px; }
       section:first-child { margin-top: 20px; }
       """ <> @parts <> @motion

  # The parts again, each rule scoped to an element with the `stampede`
  # class. LiveDashboard has no dark theme, so it's light only, and it styles
  # some of the same elements, which the last rules put back.
  @embedded_css [
                  ".stampede {\n",
                  @light,
                  "  color: var(--ink);\n  font-size: 14px;\n  line-height: 1.5;\n}\n",
                  ".stampede * { box-sizing: border-box; }\n",
                  for [_rule, selectors, declarations] <-
                        Regex.scan(~r/([^{}]+)\{([^{}]*)\}/, @parts) do
                    scoped =
                      selectors
                      |> String.split(",")
                      |> Enum.map_join(", ", &(".stampede " <> String.trim(&1)))

                    [scoped, " {", declarations, "}\n"]
                  end,
                  @motion,
                  ".stampede header { background: none; position: static; }\n",
                  ".stampede h2 { line-height: 1.25; }\n",
                  ".stampede h3 { line-height: 1.5; }\n",
                  ".stampede section { margin-top: 0; }\n",
                  ".stampede section + section { margin-top: 20px; }\n"
                ]
                |> IO.iodata_to_binary()

  # The charts' tooltips. Livebook runs this too, inside Stampede.Kino.
  @chart_js """
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
  """

  @js @chart_js <> "\nsetupCharts(document);\n"

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
    document("Stampede report", "Report", Enum.map(results, &scenario(&1, nil, [])), [])
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

    document("Stampede dashboard", "Dashboard", body, @poll_js)
  end

  # Each run is a map with an `:id`, its `:scenario` and `:status`, and
  # either its `:result` once it is over, or what the dashboard collected so
  # far: its `:timeline`, the last `:summaries` of every metric, the `:totals`
  # of their counts, and how long it is `:planned` to last.
  def runs([]), do: ~s(<p class="meta notice">Waiting for a run to start.</p>\n)
  def runs(runs), do: Enum.map(runs, &run(&1, downloads(&1.id)))

  # One run, as shown inside another page, which has no downloads to offer.
  def embedded(run), do: run |> run([]) |> IO.iodata_to_binary()

  # The styles that `embedded/1` needs, scoped to an element with the
  # `stampede` class.
  def embedded_css, do: @embedded_css

  # What sets up the charts' tooltips in an element, as `setupCharts(root)`.
  def chart_js, do: @chart_js

  defp run(%{result: %Result{} = result} = run, links), do: scenario(result, run.id, links)
  defp run(run, _links), do: live(run)

  defp document(title, label, body, script) do
    live = if script == [], do: [], else: ~s(<span class="live">Updates every second</span>)

    IO.iodata_to_binary([
      ~s(<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n),
      ~s(<meta name="viewport" content="width=device-width, initial-scale=1">\n),
      "<title>",
      title,
      "</title>\n<style>\n",
      @css,
      "</style>\n</head>\n<body>\n",
      ~s(<header class="topbar"><div><span class="brand">),
      "Stampede</span><h1>",
      label,
      "</h1>",
      live,
      "</div></header>\n<main>\n",
      body,
      "</main>\n<script>\n",
      @js,
      script,
      "</script>\n</body>\n</html>\n"
    ])
  end

  ## A run while it goes

  defp live(run) do
    last = List.last(run.timeline)
    at = if last, do: last.at, else: 0

    result = %Result{
      scenario: run.scenario,
      duration: max(run.planned, at),
      timeline: run.timeline,
      metrics: run.summaries
    }

    status =
      case run.status do
        :running -> ~s(<span class="status running">Running</span>)
        :stopped -> ~s(<span class="status failed">Stopped</span>)
      end

    progress =
      if run.status == :running and run.planned > 0 do
        percent = min(round(at / run.planned * 100), 100)

        ~s(<div class="progress" role="progressbar" aria-valuenow="#{percent}" aria-valuemin="0" aria-valuemax="100"><span style="width: #{percent}%"></span></div>\n)
      else
        []
      end

    [
      section_start(run.id, run.scenario, status),
      seconds(at),
      if(run.planned > 0, do: [" of ", seconds(run.planned)], else: " so far"),
      "</p>\n",
      progress,
      "</header>\n",
      live_tiles(run, last),
      if(last,
        do: charts(result),
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
    totals = run.totals
    main = main_metric(run.summaries, [])

    throughput =
      case throughput_metric(totals) do
        "iteration" ->
          iteration = metrics["iteration"]

          [
            {"Iterations", integer(Map.get(totals, "iteration", 0))},
            {"Iterations per second", decimal(if iteration, do: iteration.rate, else: 0)}
          ]

        nil ->
          []

        counter ->
          rate = get_in(metrics, [counter, :rate])
          [{"Messages per second", if(rate, do: integer(round(rate)), else: "–"), counter}]
      end

    latency =
      case main do
        nil -> [{"Iteration p95", "–"}]
        name -> [{p95_label(name), p95(metrics[name]), "the last second"}]
      end

    errors = Map.get(totals, "iteration.errors", 0)
    vus = if last, do: last.vus, else: 0

    tiles =
      [{"VUs", integer(vus)}] ++
        throughput ++ latency ++ [{"Errors", integer(errors), nil, if(errors > 0, do: "bad")}]

    llm? = Map.has_key?(totals, "llm.tokens.output")
    tile_grid(tiles ++ if(llm?, do: llm_tiles(metrics), else: []))
  end

  # Runs against AI model servers also show what those are judged by. A
  # second of a live run can go by without a finished request.
  defp llm_tiles(metrics) do
    tokens = metrics["llm.tokens.output"]

    [
      {"TTFT p95", p95(metrics["llm.ttft"])},
      {"Inter-token p95", p95(metrics["llm.itl"])},
      {"Tokens per second", if(tokens, do: decimal(tokens.rate), else: "–")}
    ]
  end

  defp p95(nil), do: "–"
  defp p95(metric), do: milliseconds(metric.p95)

  defp p95_label("iteration"), do: "Iteration p95"
  defp p95_label(name), do: escape(name) <> " p95"

  # The timing to lead with: the first one a threshold judges, or else the
  # most telling one the run has.
  defp main_metric(metrics, thresholds) do
    judged =
      for %{metric: name} <- thresholds,
          not String.starts_with?(name, "server."),
          do: name

    Enum.find(judged ++ @main_metrics, &match?(%{type: :timing}, metrics[&1]))
  end

  # What a run gets through: finished iterations, or for VUs that hold a
  # connection the whole run, the messages they hear.
  defp throughput_metric(totals) do
    cond do
      Map.get(totals, "iteration", 0) > 0 -> "iteration"
      counter = Enum.find(@message_counters, &(Map.get(totals, &1, 0) > 0)) -> counter
      true -> nil
    end
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

  ## A run that's over

  defp scenario(%Result{} = result, id, links) do
    {checks, metrics} = Enum.split_with(result.metrics, &match?({_name, %{type: :check}}, &1))

    [
      section_start(id, result.scenario, status(result)),
      "Ran for ",
      seconds(result.duration),
      nodes(result.server),
      links,
      "</p></header>\n",
      verdict(result.limit),
      result_tiles(result),
      busy(busy_warning(result)),
      charts(result, false),
      server(result),
      limit(result.limit),
      metrics(metrics),
      checks(checks),
      thresholds(result.thresholds),
      errors(result.errors),
      timeline(result),
      "</section>\n"
    ]
  end

  defp nodes(%{nodes: [_ | _] = nodes}), do: [" · against ", escape(Enum.join(nodes, ", "))]
  defp nodes(_server), do: []

  defp status(%Result{thresholds: []}), do: []
  defp status(%Result{passed?: true}), do: ~s(<span class="status passed">Passed</span>)
  defp status(%Result{passed?: false}), do: ~s(<span class="status failed">Failed</span>)

  # A --find-limit run leads with its answer.
  defp verdict(nil), do: []

  # Holding all it was asked to try says nothing the Limit tile doesn't.
  defp verdict(%{up_to?: true}), do: []

  defp verdict(limit) do
    {first, rest} =
      case String.split(limit_headline(limit), ". ", parts: 2) do
        [first, rest] -> {first, rest}
        [first] -> {first, nil}
      end

    class = if limit.value == nil, do: "verdict over", else: "verdict"

    [
      ~s(<div class="#{class}"><strong>),
      escape(first),
      "</strong>",
      if(rest, do: ["<p>", escape(String.trim_trailing(rest, ".")), ".</p>"], else: []),
      "</div>\n"
    ]
  end

  defp result_tiles(result) do
    %{metrics: metrics, thresholds: thresholds} = result
    totals = Map.new(metrics, fn {name, summary} -> {name, Map.get(summary, :count, 0)} end)

    limit =
      case result.limit do
        %{value: nil} ->
          [{"Limit", "none", "the first step failed", "bad"}]

        %{value: value, by: by, up_to?: up_to?} ->
          note =
            if by == :vus, do: "VUs, the most that held", else: "a second, the most that held"

          [{"Limit", amount(value, by) <> if(up_to?, do: "+", else: ""), note, "good"}]

        nil ->
          []
      end

    peak = result.timeline |> Enum.map(& &1.vus) |> Enum.max(fn -> 0 end)

    throughput =
      case throughput_metric(totals) do
        counter when counter in @message_counters ->
          summary = metrics[counter]

          [
            {"Messages", integer(summary.count), counter},
            {"Messages per second", integer(round(summary.rate))}
          ]

        "iteration" ->
          iteration = metrics["iteration"]

          [
            {"Iterations", integer(count(metrics, "iteration"))},
            {"Iterations per second", decimal(iteration.rate)}
          ]

        # VUs that only hold a connection have nothing else to count.
        nil ->
          []
      end

    latency =
      case main_metric(metrics, thresholds) do
        nil -> [{"Iteration p95", "–"}]
        name -> [{p95_label(name), milliseconds(metrics[name].p95)}]
      end

    errors = count(metrics, "iteration.errors")

    tiles =
      limit ++
        throughput ++
        latency ++
        [
          {"Errors", integer(errors), nil, if(errors > 0, do: "bad")},
          {"Peak VUs", integer(peak)}
        ] ++
        if(metrics["iterations.dropped"],
          do: [{"Dropped", integer(count(metrics, "iterations.dropped"))}],
          else: []
        ) ++ if(metrics["llm.tokens.output"], do: llm_tiles(metrics), else: [])

    tile_grid(tiles)
  end

  # On the dashboard, finished runs can be saved as the report and the JSON.
  defp downloads(id) do
    [
      ~s( · <a href="runs/#{id}/report.html" download>HTML report</a>),
      ~s( · <a href="runs/#{id}/results.json" download>JSON</a>)
    ]
  end

  defp server(%Result{server: nil}), do: []

  defp server(%Result{server: server} = result) do
    tiles = [
      {"Server schedulers", "#{round(server.busy * 100)}% busy", "at their busiest",
       if(server.busy >= 0.9, do: "bad")},
      {"Server memory", bytes(server.memory)},
      {"Server processes", integer(server.processes)},
      {"Server run queue", integer(server.run_queue)}
    ]

    tiles =
      case server do
        %{database: %{} = database, pool: %{} = pool} ->
          tiles ++
            [
              {"Database commits", integer(round(database.commits)) <> "/s"},
              {"Database pool wait", milliseconds(pool.wait_ms), "of #{pool.size} connections"}
            ]

        %{pool: %{} = pool} ->
          tiles ++
            [{"Database pool wait", milliseconds(pool.wait_ms), "of #{pool.size} connections"}]

        _no_database ->
          tiles
      end

    queues =
      for %{length: length, process: process} <- server.queues do
        [integer(length), " &middot; ", escape(process), "<br>\n"]
      end

    [
      "<h3>Server</h3>\n",
      ~s(<p class="meta">At its busiest: ),
      escape(Enum.join(server.nodes, ", ")),
      "</p>\n",
      tile_grid(tiles),
      if(queues != [],
        do: [
          ~s(<p class="meta queues"><strong>Longest message queues</strong><br>\n),
          queues,
          "</p>\n"
        ],
        else: []
      ),
      server_charts(result, false)
    ]
  end

  defp busy(nil), do: []

  defp busy(warning),
    do: [~s(<p class="warning"><strong>Warning:</strong> ), escape(warning), "</p>\n"]

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

    ["<h3>Steps</h3>\n", table(header, rows)]
  end

  defp tile_grid(tiles) do
    [
      ~s(<div class="tiles">\n),
      for tile <- tiles do
        {label, value, note, class} =
          case tile do
            {label, value} -> {label, value, nil, nil}
            {label, value, note} -> {label, value, note, nil}
            {label, value, note, class} -> {label, value, note, class}
          end

        [
          if(class, do: ~s(<div class="tile #{class}">), else: ~s(<div class="tile">)),
          "<span>",
          label,
          "</span><strong>",
          value,
          "</strong>",
          if(note, do: ["<small>", escape(note), "</small>"], else: []),
          "</div>\n"
        ]
      end,
      "</div>\n"
    ]
  end

  ## Charts

  # A finished run shows the server's charts with its numbers instead.
  defp charts(result, server? \\ true)
  defp charts(%Result{timeline: []}, _server?), do: []

  defp charts(result, server?) do
    %{timeline: timeline, metrics: metrics} = result
    totals = Map.new(metrics, fn {name, summary} -> {name, Map.get(summary, :count, 0)} end)
    rate = fn name -> Enum.map(timeline, &(get_in(&1.metrics, [name, :rate]) || 0)) end

    throughput =
      case throughput_metric(totals) do
        counter when counter in @message_counters ->
          [
            chart("Messages per second", result, [{"messages", 1, rate.(counter)}], :rate),
            chart("Errors per second", result, [{"errors", 2, rate.("iteration.errors")}], :rate)
          ]

        nil ->
          if Map.has_key?(metrics, "iteration.errors"),
            do: [
              chart(
                "Errors per second",
                result,
                [{"errors", 2, rate.("iteration.errors")}],
                :rate
              )
            ],
            else: []

        "iteration" ->
          series =
            for {name, label, slot} <- [
                  {"iteration", "iterations", 1},
                  {"iteration.errors", "errors", 2},
                  {"iterations.dropped", "dropped", 3}
                ],
                name == "iteration" or Map.has_key?(metrics, name) do
              {label, slot, rate.(name)}
            end

          [chart("Iterations per second", result, series, :rate)]
      end

    # What the server timed has no seconds of its own to chart.
    timings =
      for {name, %{type: :timing}} <- metrics,
          not String.starts_with?(name, "server."),
          do: name

    main = main_metric(metrics, result.thresholds)

    latencies =
      for name <- Enum.sort_by(timings, &{&1 != main, &1 != "iteration", &1}) do
        series =
          for {stat, slot} <- @percentiles do
            {Atom.to_string(stat), slot, Enum.map(timeline, &get_in(&1.metrics, [name, stat]))}
          end

        limits =
          for %{metric: ^name, stat: stat, limit: limit} <- result.thresholds,
              stat in [:mean, :p50, :p90, :p95, :p99, :max],
              do: {"#{stat} limit #{milliseconds(limit)}", limit}

        chart(name, result, series, :ms, limits: limits)
      end

    vus =
      chart("VUs", result, [{"VUs", 1, Enum.map(timeline, & &1.vus)}], :count,
        area: true,
        bands: if(result.limit, do: result.limit.steps, else: [])
      )

    [
      group("Load", [vus], throughput),
      group("Latency", [], latencies),
      if(server?, do: server_charts(result), else: [])
    ]
  end

  # A heading and its charts. Wide charts take a row of their own, and the
  # rest go three to a row, or two when that leaves none alone.
  defp group(_title, [], []), do: []

  defp group(title, wide, charts) do
    [
      "<h3>",
      title,
      "</h3>\n",
      if(wide != [],
        do: [~s(<div class="charts">\n), Enum.map(wide, &draw(&1, :wide)), "</div>\n"],
        else: []
      ),
      group_charts(charts)
    ]
  end

  defp group_charts([]), do: []

  defp group_charts(charts) do
    {class, size} =
      if rem(length(charts), 3) != 0, do: {"charts pairs", :half}, else: {"charts", :third}

    [~s(<div class="#{class}">\n), Enum.map(charts, &draw(&1, size)), "</div>\n"]
  end

  defp server_charts(%{timeline: timeline} = result, headed? \\ true) do
    if Enum.any?(timeline, &Map.has_key?(&1, :server)) do
      values = fn key, scale ->
        # A second the probe didn't measure is a gap in the line.
        Enum.map(timeline, fn point ->
          case point[:server] do
            %{^key => value} when is_number(value) -> scale.(value)
            _missing -> nil
          end
        end)
      end

      server = [
        chart(
          "Server schedulers, % busy",
          result,
          [{"busy", 1, values.(:busy, &(&1 * 100))}],
          :percent
        ),
        chart("Server memory, GB", result, [{"memory", 1, values.(:memory, &(&1 / 1.0e9))}], :gb),
        chart("Server processes", result, [{"processes", 1, values.(:processes, & &1)}], :count),
        chart("Server run queue", result, [{"run queue", 1, values.(:run_queue, & &1)}], :count)
      ]

      database = database_charts(result)

      [
        if(headed?, do: group("Server", [], server), else: group_charts(server)),
        group("Database", [], database)
      ]
    else
      []
    end
  end

  # What the probe saw of the app's database pool and its Postgres.
  defp database_charts(%{timeline: timeline} = result) do
    value = fn path ->
      Enum.map(timeline, fn point -> get_in(point, [:server | path]) end)
    end

    pool =
      if Enum.any?(timeline, &get_in(&1, [:server, :pool])),
        do: [
          chart("Database pool wait, ms", result, [{"wait", 1, value.([:pool, :wait_ms])}], :ms)
        ],
        else: []

    database =
      if Enum.any?(timeline, &get_in(&1, [:server, :database])) do
        [
          chart(
            "Database commits and writes, per second",
            result,
            [
              {"commits", 1, value.([:database, :commits])},
              {"rows written", 2, value.([:database, :writes])}
            ],
            :rate
          ),
          chart(
            "Database active queries",
            result,
            [{"active", 1, value.([:database, :active])}],
            :count
          )
        ]
      else
        []
      end

    pool ++ database
  end

  # What a chart shows, drawn once its group knows where it goes.
  defp chart(title, result, series, unit, opts \\ []),
    do: {:chart, title, result, series, unit, opts}

  defp draw({:chart, title, result, series, unit, opts}, size) do
    wide? = size == :wide
    {width, height} = Map.fetch!(@sizes, size)
    x = fn at -> x(at, result.duration, width) end
    xs = Enum.map(result.timeline, &x.(&1.at))

    max =
      series
      |> Enum.flat_map(&elem(&1, 2))
      |> Enum.reject(&is_nil/1)
      |> Enum.max(fn -> 0 end)

    # A limit close enough to the line is worth stretching the axis for.
    limits = Keyword.get(opts, :limits, [])
    shown = for {_label, limit} <- limits, max > 0, limit <= max * 3, do: limit
    {top, ticks} = y_ticks(Enum.max([max | shown]), unit)
    y = fn value -> @top + (1 - value / top) * (height - @top - @bottom) end

    data = %{
      width: width,
      x: Enum.map(xs, &round1/1),
      at: Enum.map(result.timeline, &seconds(&1.at)),
      series:
        for {name, slot, values} <- series do
          %{name: name, slot: slot, values: Enum.map(values, &value(&1, unit))}
        end
    }

    [
      if(wide?,
        do: ~s(<figure class="chart wide" tabindex="0" data-points="),
        else: ~s(<figure class="chart" tabindex="0" data-points=")
      ),
      escape(JSON.encode!(data)),
      ~s(">\n<figcaption><b>),
      escape(title),
      "</b>",
      legend(series),
      "</figcaption>\n",
      ~s(<svg viewBox="0 0 #{width} #{height}" role="img" aria-label="),
      escape(title),
      ~s(">\n),
      bands(Keyword.get(opts, :bands, []), x, result.duration, height),
      y_axis(ticks, y, unit, width),
      x_axis(result.duration, width, height),
      limit_lines(limits, top, y, width),
      if(Keyword.get(opts, :area, false), do: area(hd(series), xs, y, height), else: []),
      Enum.map(series, &series(&1, xs, y)),
      ~s(<line class="cross" y1="#{@top}" y2="#{height - @bottom}"/>\n),
      ~s(</svg>\n<div class="tip" hidden></div>\n</figure>\n)
    ]
  end

  # Each step of a --find-limit run, shaded by whether it held.
  defp bands(steps, x, duration, height) do
    for %{from: _from, to: _to} = step <- steps, step.from < duration do
      from = round1(x.(step.from))
      to = round1(x.(min(step.to, duration)))
      class = if step.passed?, do: "held", else: "over"

      [
        ~s(<rect class="band #{class}" x="#{from}" y="#{@top}" width="#{round1(to - from)}" ),
        ~s(height="#{height - @top - @bottom}"/>),
        ~s(<text class="band-label #{class}" x="#{round1(to - 6)}" y="#{@top + 12}" text-anchor="end">),
        tick(step.target, :count),
        "</text>\n"
      ]
    end
  end

  defp limit_lines(limits, top, y, width) do
    for {label, limit} <- limits, limit <= top do
      position = round1(y.(limit))

      [
        ~s(<line class="limit" x1="#{@left}" x2="#{width - @right}" y1="#{position}" y2="#{position}"/>),
        ~s(<text class="limit-label" x="#{width - @right}" y="#{round1(position - 4)}" text-anchor="end">),
        escape(label),
        "</text>\n"
      ]
    end
  end

  # The shape under the first line, so the load reads at a glance.
  defp area({_name, slot, values}, xs, y, height) do
    floor = height - @bottom

    xs
    |> Enum.zip(values)
    |> Enum.chunk_by(&is_nil(elem(&1, 1)))
    |> Enum.reject(fn [{_x, value} | _rest] -> is_nil(value) end)
    |> Enum.map(fn [{first, _value} | _rest] = points ->
      {last, _value} = List.last(points)

      path =
        Enum.map_intersperse(points, " L", fn {x, value} ->
          "#{round1(x)},#{round1(y.(value))}"
        end)

      [
        ~s(<path class="area s#{slot}" d="M#{round1(first)},#{floor} L),
        path,
        ~s( L#{round1(last)},#{floor} Z"/>\n)
      ]
    end)
  end

  defp legend([_single]), do: []

  defp legend(series) do
    for {name, slot, _values} <- series do
      [~s(<span><i class="key k#{slot}"></i>), escape(name), "</span>"]
    end
  end

  defp y_axis(ticks, y, unit, width) do
    for tick <- ticks do
      position = round1(y.(tick))
      class = if tick == 0, do: "axis", else: "grid"

      [
        ~s(<line class="#{class}" x1="#{@left}" x2="#{width - @right}" ),
        ~s(y1="#{position}" y2="#{position}"/>),
        ~s(<text x="#{@left - 6}" y="#{position}" dy="0.32em" text-anchor="end">),
        tick(tick, unit),
        "</text>\n"
      ]
    end
  end

  defp x_axis(duration, width, height) do
    count = div(width, 90)
    step = Enum.find(@steps, List.last(@steps), &(duration / &1 <= count))

    for at <- 0..duration//step do
      ~s(<text x="#{round1(x(at, duration, width))}" y="#{height - 6}" text-anchor="middle">) <>
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

  defp x(at, duration, width), do: @left + at / max(duration, 1) * (width - @left - @right)

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
  defp value(value, :percent), do: "#{round(value)}%"
  defp value(value, :gb), do: decimal(value) <> " GB"

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
      ~s(<h3>Errors</h3>\n<div class="table-wrap errors"><table><tbody>\n),
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
      ~s(<div class="table-wrap"><table>\n<thead><tr>),
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
