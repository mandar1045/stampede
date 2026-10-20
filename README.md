# Stampede

Load testing for Elixir and Phoenix, with built-in Phoenix Channels and LiveView support.

Generic load testing tools see a Phoenix channel as a plain WebSocket, so each
test has to rebuild the protocol by hand: join messages, refs, replies and
heartbeats. LiveView is harder still, since every session starts with a page
load that hands out the tokens the socket needs. Stampede speaks both
natively. Every virtual user (VU) is a BEAM process, and scenarios are plain
Elixir modules, so one machine can hold thousands of connections and your
load tests can reuse your own code.

> Stampede is new and its API may still change before 1.0.

## Installation

```elixir
def deps do
  [
    {:stampede, "~> 0.1", only: :dev}
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
over. At the end it prints a summary like this one, from a run with 5,000 VUs
against a Phoenix app on the same laptop:

```
Demo.Chat ran for 15.0s

  metric         count   rate/s     mean      p50      p90      p95       p99       max
  channel.join    5000   333.24  14.41ms   8.69ms  25.09ms  59.30ms   92.07ms  101.76ms
  channel.push  115636  7707.01   3.83ms   1.20ms  10.41ms  15.22ms   28.86ms  129.36ms
  ws.connect      5000   333.24  19.16ms  13.23ms  26.64ms  41.37ms  174.62ms  174.62ms

  thresholds
    pass  channel.join p95 <= 500.00ms (59.30ms)
    pass  channel.push p99 <= 500.00ms (28.86ms)
    pass  iteration.errors count <= 0 (0)
```

The task exits with status 1 when a threshold fails, so it can run in CI.
`--vus 100 --duration 1m` replaces the stages with a constant number of VUs.

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

## Stages and thresholds

Stages are `{duration, target}` tuples. Each one moves the number of VUs in a
straight line from the previous target to its own. Durations are milliseconds
or anything `Kernel.to_timeout/1` accepts, such as `[second: 30]`.

Thresholds are the highest value a statistic may reach for the run to pass:

```elixir
thresholds: [
  {"channel.join", p95: 250, max: 2_000},
  {"channel.push.errors", rate: 0.5},
  {"iteration.errors", count: 0}
]
```

Timings have `min`, `mean`, `p50`, `p90`, `p95`, `p99` and `max`, in
milliseconds. Every metric has `count` and `rate`, per second. Percentiles are
within 1% of the exact value, however many samples a run collects.

## Metrics

Stampede records `iteration`, `iteration.errors` and `vu.crashes` for every
scenario. `Stampede.Channels` adds `ws.connect`, `ws.disconnects`,
`channel.join`, `channel.push`, `channel.leave` and `channel.messages`, plus an
`.errors` counter for each request type.

Record your own with `Stampede.measure/2`, `Stampede.record/3` and
`Stampede.increment/2`:

```elixir
Stampede.measure("broadcast.roundtrip", fn ->
  :ok = Stampede.Channels.cast(socket, "room:lobby", "shout", %{body: "hi"})
  {:ok, _payload} = Stampede.Channels.await(socket, "room:lobby", "shout")
end)
```

## Phoenix Channels

`Stampede.Channels` covers what a JavaScript client does:

  * `connect/2` with params, headers and either serializer (`"2.0.0"` or `"1.0.0"`)
  * `join/4`, `push/5` and `leave/3`, which wait for the reply
  * `cast/4` for events the channel does not reply to
  * `await/4` for pushes and broadcasts from the server
  * heartbeats, sent every 30 seconds by default

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
end
```

`click/4`, `change/4` and `submit/4` send what `phx-click`, `phx-change` and
`phx-submit` would, and return what `handle_event/3` replied, if anything.
`await/2` waits for updates the LiveView sends on its own. A run records
`live.page`, `live.join` and `live.event`, and a LiveView that crashes on an
event fails it with `{:error, :channel_crashed}` instead of a timeout.

With the server on the same laptop, 3,000 LiveView users that each load the
page, join and click every 500ms ran with no errors, a join p95 of 117ms and
an event p99 of 14ms.

## Running from code

Load tests can also run from a script, without a Mix project:

```elixir
Mix.install([{:stampede, "~> 0.1"}])

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

  * LiveView uploads, components targeted with `phx-target`, and following
    redirects
  * Spreading the load over several machines with Erlang distribution
  * Telemetry events and a live dashboard
  * Plain WebSocket and TCP clients

## License

Copyright 2026 Mandar Joshi

Licensed under the Apache License, Version 2.0, found in the LICENSE file.
