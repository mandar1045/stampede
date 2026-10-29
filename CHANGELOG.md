# Changelog

## v1.2.0 (2026-10-29)

This one answers the question I get asked most: how many users can my app
handle? It also comes out of a real test on AWS, where stock Phoenix on one
4-core server held 400,000 Channels users with no errors. That run found
the problems with Stampede itself fixed below, and everything needed to run
it again is in `bench/million`.

  * `--find-limit`, or `find_limit:` from code, answers "how many users can
    it handle?": the load goes up a step at a time until a threshold fails,
    and the result says the most users, or the highest rate, that passed.
    It's new, so its options and report may still change
  * `--badge`, and `Stampede.Reporter.to_badge/1`, write a README badge with
    the limit found
  * `mix stampede.gen.scenario --rate` generates a scenario that starts
    iterations at a rate
  * `mix stampede.compare --format markdown`, to post a comparison on a pull
    request
  * Finished runs on the dashboard can be downloaded as the HTML report or
    the JSON
  * Channels and WebSocket connections hibernate after 5 seconds without
    traffic. A VU holding a Channels connection went from about 37 KB of
    memory to 23 KB, which matters once you're holding hundreds of thousands
  * WebSocket connections use a 64 KB socket buffer instead of the few
    megabytes Mint sets. With 60,000 connections, that cut the load test's
    CPU by about a fifth
  * Runs measure how busy the load test itself is, every second. When it's
    90% busy or more, its own delays end up in its timings, so the summary
    and the HTML report say so, and a `--find-limit` verdict says the limit
    may be the load test's rather than the server's
  * A run ends on time and prints its summary even when its VUs keep the
    machine 100% busy. Its own processes run at high priority, and progress
    is printed without holding the run up
  * A VU whose iterations keep failing waits longer between tries: 100 ms,
    then 150, 200, 250, 500 ms, 1 s, 2 s and at most 5 s, much like Phoenix's
    JavaScript client before it reconnects. It was 100 ms every time, which
    piled more load onto a server, or a load test, that was already in
    trouble
  * Connections no longer go through Erlang's host lookup for every
    connect. IP addresses are used as they are, and host names are looked
    up once and kept for 5 minutes. Under heavy load, lookups queued behind
    each other and timed out as `nxdomain` errors that looked like the
    server failing
  * A run warns before it starts when a node may not allow enough processes
    or open files for its VUs, instead of failing halfway with errors that
    don't say why. It checks `ulimit -n` too, which the BEAM doesn't report

## v1.1.0 (2026-10-24)

This release is mostly about seeing what a load test is doing while it runs,
and about covering more of a Phoenix app.

  * A live dashboard: `mix stampede.run --dashboard`, or `Stampede.Dashboard`
    from code
  * `--parallel` and `Stampede.run_parallel/2` run several scenarios at once,
    each with its own options
  * LiveView uploads with `Stampede.LiveView.upload/4`, recorded as
    `"live.upload"`
  * `mix stampede.gen.scenario` generates HTTP, Channels, LiveView and
    WebSocket scenarios
  * `mix igniter.install stampede` adds Stampede and a first scenario to a
    project
  * `Stampede.ExUnit` runs load tests from a test suite
  * Binary payloads in `Stampede.Channels` with the `"2.0.0"` serializer, as
    `{:binary, data}`
  * Custom serializers through `Stampede.Channels.Serializer` and the
    `:serializer` option, for servers that extend the protocol
  * Elixir 1.18 is supported
  * New guides: pages behind a login, Phoenix Presence, Absinthe
    subscriptions, load tests in CI, spreading the load over machines, and a
    case study with real numbers

### Fixes

  * A payload that cannot be encoded raises in the caller of `push/5` or
    `cast/4`, instead of crashing the socket.

## v1.0.0 (2026-10-20)

First release.

  * Scenarios with setup data, stages and thresholds
  * Closed runs that keep a number of VUs busy, and open runs that start
    iterations at a rate with `:rate`, `:rate_stages` and `:max_vus`
  * `:graceful_stop`, to let VUs finish their iteration during a ramp down
    and at the end of the run
  * Timings with percentiles accurate to 1%, counters, and checks with
    `Stampede.check/2`
  * A Phoenix Channels client with heartbeats, replies, broadcasts and both
    serializers
  * A LiveView client that loads the page, following redirects, joins with
    its tokens and cookies, sends clicks, form changes and submits to the
    LiveView or one of its components, and patches and navigates between
    LiveViews
  * `Stampede.HTTP`, a client that keeps each VU's connections open between
    requests
  * `Stampede.WebSocket`, a client for plain WebSockets
  * Runs spread over several nodes with `:nodes`, loading the scenario on
    the nodes that miss it
  * A timeline of every second of the run, and telemetry events for runs,
    timings, counters and checks
  * Reports for the terminal, as JSON and as an HTML page with charts
  * `mix stampede.run`, which exits with status 1 when a threshold fails, and
    `mix stampede.compare`, to compare two runs and fail on regressions
