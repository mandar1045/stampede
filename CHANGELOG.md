# Changelog

## Unreleased

  * Binary payloads in `Stampede.Channels`, sent and received as
    `{:binary, data}` with the `"2.0.0"` serializer, as in Phoenix
  * `Stampede.Channels.Serializer`, with a `:serializer` option in
    `Stampede.Channels.connect/2` for servers that extend the protocol

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
