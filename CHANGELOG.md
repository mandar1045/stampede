# Changelog

## v0.3.0 (2026-10-20)

  * `:graceful_stop`, to let VUs finish their iteration during a ramp down
    and at the end of the run
  * HTML reports with charts, from `Stampede.Reporter.to_html/1` and
    `mix stampede.run --html`
  * `mix stampede.compare`, to compare the timings of two runs and fail on
    regressions with `--max-regression`
  * `Stampede.WebSocket`, a client for plain WebSockets

### Changes

  * A `:rate` run starts its first iteration right away, so it starts
    exactly `rate * duration` iterations instead of one less.
  * The timeline ends with a point for the end of the plan, and one more for
    the time VUs took to stop when `:graceful_stop` is set.

### Fixes

  * Frames a server sends in the same packet as the upgrade response are no
    longer dropped.

## v0.2.0 (2026-10-20)

  * Start iterations at a rate with `:rate`, `:rate_stages` and `:max_vus`,
    reusing idle VUs and counting the iterations that cannot start as
    `"iterations.dropped"`
  * Spread a run over several nodes with `:nodes`, or `--nodes` from the
    command line, loading the scenario on the nodes that miss it
  * `Stampede.HTTP`, a client that keeps each VU's connections open between
    requests and records `"http.request"`
  * Checks, with `Stampede.check/2` and the `:failed` and `:failed_rate`
    thresholds
  * A timeline of every second of the run in `Stampede.Result`
  * `Stampede.Reporter.to_json/1` and `mix stampede.run --out`
  * Telemetry events for runs, timings, counters and checks
  * A `:match` option for `Stampede.Channels.await/4` and
    `Stampede.LiveView.await/2`
  * `mix stampede.run --rate` and `--max-vus`

### Changes

  * LiveView page loads reuse their connection, as browsers do. A server
    holds an idle connection per user as a result, so numbers can differ from
    the ones measured with 0.1.
  * Runs no longer leave monitor messages in the caller's mailbox.

## v0.1.0 (2026-10-20)

First release.

  * Scenarios with stages, setup data and thresholds
  * Timings with percentiles accurate to 1%, and counters
  * A Phoenix Channels client with heartbeats, replies, broadcasts and both serializers
  * A LiveView client that loads the page, following redirects, joins with its
    tokens and cookies, sends clicks, form changes and submits to the LiveView
    or one of its components, and patches and navigates between LiveViews
  * `mix stampede.run`, which exits with status 1 when a threshold fails
