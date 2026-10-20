# Stampede

Load testing for Elixir and Phoenix, with built-in Phoenix Channels and LiveView support.

Generic load testing tools see a Phoenix channel as a plain WebSocket, so each
test has to rebuild the protocol by hand: join messages, refs, replies and
heartbeats. LiveView is harder still, since every session starts with a page
load that hands out the tokens the socket needs. Stampede speaks both
natively, along with plain HTTP and WebSockets.

Every virtual user (VU) is a BEAM process and scenarios are plain Elixir
modules, so one machine can hold thousands of connections, several machines
can share one test over Erlang distribution, and your load tests can reuse
your own code.

## Installation

```elixir
def deps do
  [
    {:stampede, "~> 1.0", only: :dev}
  ]
end
```

Stampede requires Elixir 1.19 or later.

## A first load test

Create `loadtest/lobby.exs`:

```elixir
defmodule MyApp.Load.Lobby do
  use Stampede.Scenario

  @impl true
  def options do
    [
      stages: [{[second: 30], 500}, {[minute: 1], 500}, {[second: 10], 0}],
      thresholds: [{"channel.join", p95: 250}, {"iteration.errors", count: 0}]
    ]
  end

  @impl true
  def run(vu) do
    {:ok, socket} = Stampede.Channels.connect("ws://localhost:4000/socket")
    {:ok, _reply} = Stampede.Channels.join(socket, "room:lobby")

    for _ <- 1..10 do
      {:ok, _reply} = Stampede.Channels.push(socket, "room:lobby", "new_msg", %{body: "hi from #{vu.id}"})
      Process.sleep(1_000)
    end
  end
end
```

And run it:

```console
$ mix stampede.run loadtest/lobby.exs
```

Stampede ramps up to 500 VUs over 30 seconds, holds them for a minute and
ramps down, printing progress every second. Each VU calls `run/1` over and
over. At the end it prints a summary like this one, from a run with 6,000 VUs
spread over three nodes, against a Phoenix app on the same laptop:

```
Demo.Chat ran for 15.0s

  metric          count   rate/s     mean     p50      p90      p95      p99       max
  channel.join     6000   399.89  10.72ms  5.49ms  18.59ms  31.90ms  97.77ms  103.81ms
  channel.push   139348  9287.39   2.56ms   854µs   6.84ms  11.27ms  22.25ms   55.84ms
  ws.connect       6000   399.89  16.28ms 11.50ms  28.29ms  35.25ms 134.64ms  209.06ms

  thresholds
    pass  channel.join p95 <= 500.00ms (31.90ms)
    pass  iteration.errors count <= 0 (0)
```

The task exits with status 1 when a threshold fails, so it can run in CI.

## Scenarios

A scenario implements `Stampede.Scenario`:

  * `run/1` runs one iteration of a VU. It gets a `Stampede.VU` with the VU's
    `id`, its `iteration` count and the `data` returned by `setup/1`.
  * `options/0` returns the default options of the run, optional.
  * `setup/1` runs once before the first VU starts, optional. Use it to create
    accounts or sign tokens that every VU needs.

If an iteration raises, the error is counted under `iteration.errors`, shown
in the summary, and the VU moves on to its next iteration. Sockets opened
during an iteration are closed when it ends.

## VUs or a rate

A run either keeps a number of VUs busy, or starts iterations at a rate.

`stages` are `{duration, target}` tuples, each moving the number of VUs in a
straight line from the previous target to its own. `vus: 100, duration:
[minute: 1]` holds 100 VUs for a minute. Durations are milliseconds or
anything `Kernel.to_timeout/1` accepts, such as `[second: 30]`.

A VU only starts its next iteration once the last one is done, so when the
server slows down, the load eases off too. Real users don't wait for each
other, which is why `rate` starts iterations at a fixed pace instead, however
long they take:

```elixir
[rate: 200, duration: [minute: 5], max_vus: 1_000]
[rate_stages: [{[minute: 1], 500}, {[minute: 5], 500}]]
```

VUs are started as needed and reused between iterations, keeping their
connections. `max_vus` caps how many iterations may be in progress, and the
ones that cannot start are counted as `iterations.dropped`.

From the command line, `--vus 100` or `--rate 200` with `--duration 1m`
replace a scenario's own settings.

VUs that are no longer needed, during a ramp down or at the end of the run,
are stopped at once. `graceful_stop: [second: 30]` lets them finish their
current iteration first, so the last iterations are recorded instead of cut
off.

## Checks and thresholds

Checks are assertions that do not end the iteration when they fail:

```elixir
{:ok, response} = Stampede.HTTP.get("http://localhost:4000/api/posts")
Stampede.check("status is 200", response.status == 200)
```

Thresholds are the highest value a statistic may reach for the run to pass:

```elixir
thresholds: [
  {"channel.join", p95: 250, max: 2_000},
  {"status is 200", failed_rate: 0.01},
  {"iteration.errors", count: 0}
]
```

Timings have `min`, `mean`, `p50`, `p90`, `p95`, `p99` and `max`, in
milliseconds. Checks have `failed` and `failed_rate`. Every metric has
`count` and `rate`, per second. Percentiles are within 1% of the exact value,
however many samples a run collects.

## Metrics

Stampede records `iteration`, `iteration.errors`, `iterations.dropped` and
`vu.crashes` for every scenario, and the clients below record their own.

Record your own with `Stampede.measure/2`, `Stampede.record/3`,
`Stampede.increment/2` and `Stampede.check/2`:

```elixir
Stampede.measure("broadcast.roundtrip", fn ->
  :ok = Stampede.Channels.cast(socket, "room:lobby", "shout", %{from: vu.id})
  {:ok, _payload} = Stampede.Channels.await(socket, "room:lobby", "shout", match: &(&1["from"] == vu.id))
end)
```

## HTTP

`Stampede.HTTP` sends requests and records them as `http.request`, counting
transport errors and statuses of 400 or more as `http.request.errors`:

```elixir
{:ok, %{status: 200, body: body}} = Stampede.HTTP.get("http://localhost:4000/api/posts")
{:ok, %{status: 201}} = Stampede.HTTP.post("http://localhost:4000/api/posts", json: %{title: "Hi"})
```

Each VU keeps its connections open between requests, as browsers do, and
reconnects when the server closed one. Against a Phoenix app on the same
laptop, 2,000 GET requests per second for 10 seconds held their rate with a
p99 of 1.56ms.

## Phoenix Channels

`Stampede.Channels` covers what a JavaScript client does:

  * `connect/2` with params, headers and either serializer (`"2.0.0"` or `"1.0.0"`)
  * `join/4`, `push/5` and `leave/3`, which wait for the reply
  * `cast/4` for events the channel does not reply to
  * `await/4` for pushes and broadcasts from the server, with an optional
    `:match` function to pick one out of many
  * heartbeats, sent every 30 seconds by default

It records `ws.connect`, `ws.disconnects`, `channel.join`, `channel.push`,
`channel.leave` and `channel.messages`, plus an `.errors` counter for each
request type. A push to a channel that crashes fails with
`{:error, :channel_crashed}` instead of a timeout.

## LiveView

`Stampede.LiveView` loads a page the way a browser does, then joins the
LiveView it renders, with the page's CSRF token and cookies:

```elixir
@impl true
def run(_vu) do
  {:ok, view} = Stampede.LiveView.connect("http://localhost:4000/posts/new")
  {:ok, _reply} = Stampede.LiveView.change(view, "validate", %{"post" => %{"title" => "Hi"}})
  {:ok, _reply} = Stampede.LiveView.submit(view, "save", %{"post" => %{"title" => "Hi there"}})
  {:ok, _reply} = Stampede.LiveView.click(view, "like", %{"id" => "1"})
  {:ok, _view} = Stampede.LiveView.navigate(view, "/posts")
end
```

`click/4`, `change/4` and `submit/4` send what `phx-click`, `phx-change` and
`phx-submit` would, and return what `handle_event/3` replied, if anything.
Pass `target: 1` to send an event to a component, like `phx-target` does.
`await/2` waits for updates the LiveView sends on its own.

`patch/3` and `navigate/3` move between pages like `<.link patch>` and
`<.link navigate>` do, over the same socket when LiveView allows it. When an
event makes the LiveView navigate on its own, it returns
`{:error, {:live_redirect, %{"to" => to}}}` as `Phoenix.LiveViewTest` does,
and `navigate/3` follows it.

`connect/2` follows redirects and keeps the cookies they set, so a route that
signs a test user in and redirects to the page under test is enough to load
test pages behind a login. A run records `live.page`, `live.join`,
`live.event`, `live.patch` and `live.navigate`.

## Plain WebSockets

`Stampede.WebSocket` is for servers that don't use Phoenix Channels, such as
a `WebSock` handler or a GraphQL subscription endpoint:

```elixir
{:ok, ws} = Stampede.WebSocket.connect("ws://localhost:4000/ws")
:ok = Stampede.WebSocket.send(ws, JSON.encode!(%{subscribe: "prices"}))
{:ok, {:text, text}} = Stampede.WebSocket.await(ws, match: &match?({:text, "{\"price\"" <> _}, &1))
```

It answers pings, and keeps the frames the server sends until `await/2`
reads them, even after the server closed the connection. It records
`ws.connect`, `ws.disconnects`, `ws.messages` and `ws.messages.sent`.

## Results

`Stampede.run/2` returns a `Stampede.Result`, with every metric's summary and
a timeline of what happened during each second of the run, to see when
latency went up during a ramp. `--out results.json` writes it all as JSON,
and so does `Stampede.Reporter.to_json/1`.

`--html report.html` writes a page with a chart of the VUs, the iterations
per second and the percentiles of every timing over the run, along with the
summary. It is a single file with nothing to load, so CI can keep it as an
artifact.

To catch regressions, compare two runs:

```console
$ mix stampede.run loadtest/api.exs --out main.json
$ git switch my-branch
$ mix stampede.run loadtest/api.exs --out branch.json
$ mix stampede.compare main.json branch.json --max-regression 10
```

It prints how the p50, p95 and p99 of every timing changed, and exits with
status 1 when one got more than 10% slower.

Stampede also emits `:telemetry` events for every timing, counter and check,
and for every second of a run, to send them to your own metrics system while
a test runs. They are listed in the `Stampede` docs.

## Spreading the load

One machine runs out of CPU or ports long before a large Phoenix app runs out
of room. Start a node on more machines, from the same project, and give them
to the task:

```console
$ iex --sname worker --cookie load -S mix
$ elixir --sname loader --cookie load -S mix stampede.run loadtest/lobby.exs --nodes worker@host
```

VUs and rates are split evenly between the nodes, and their metrics are
merged as if they ran on one. From code, pass `nodes: [node() | Node.list()]`.

## Running from code

Load tests can also run from a script, without a Mix project:

```elixir
Mix.install([{:stampede, "~> 1.0"}])

defmodule Lobby do
  use Stampede.Scenario

  @impl true
  def run(_vu) do
    {:ok, socket} = Stampede.Channels.connect("ws://localhost:4000/socket")
    {:ok, _reply} = Stampede.Channels.join(socket, "room:lobby")
    Process.sleep(1_000)
  end
end

result = Stampede.run(Lobby, vus: 100, duration: [minute: 1], progress: true)
IO.puts(Stampede.Reporter.format(result))
System.halt(if result.passed?, do: 0, else: 1)
```

## Roadmap

  * LiveView uploads
  * A live dashboard
  * A TCP client

## License

Copyright 2026 Mandar Joshi

Licensed under the Apache License, Version 2.0, found in the LICENSE file.
