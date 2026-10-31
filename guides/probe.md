# Seeing inside your app

A load test measures your app from the outside. It can tell you that joins got
slow at 40,000 users, but not whether that was the CPU, the database or one
overloaded process. With `--probe`, Stampede watches the app from the inside
during the test, and puts both views in the same report.

Your app doesn't need any changes or dependencies. All it takes is a running
BEAM node that Stampede can connect to.

## Connecting to your app

Start the app with a node name and a cookie, then run the test from a node
with the same cookie:

```console
$ elixir --name app@127.0.0.1 --cookie secret -S mix phx.server
```

```console
$ elixir --name loader@127.0.0.1 --cookie secret -S mix stampede.run loadtest/lobby.exs --probe app@127.0.0.1
```

From code, it's an option, with one node or a list of them:

```elixir
Stampede.run(MyApp.Load.Lobby, probe: :"app@127.0.0.1")
```

A release gets its name and cookie from the environment:

```console
$ RELEASE_DISTRIBUTION=name RELEASE_NODE=app@10.0.0.5 RELEASE_COOKIE=secret bin/my_app start
```

Nodes find each other through `epmd` on port 4369, then talk on a port the VM
picks at random. Behind a firewall or in a container, fix those ports and open
them to the load test, as in the
[guide to spreading the load](distributed.md#networks-and-security).

A node that knows the cookie can run any code on your app, so only do this on
a private network, with a long random cookie. If you're probing production, be
sure that's what you want.

## What it does to your app

While the run lasts, a small agent runs on the app's node:

  * Stampede loads the agent's code onto the node, and removes it afterwards.
  * It turns on the VM's scheduler statistics, and attaches telemetry handlers
    for Phoenix, LiveView and any Ecto repos it finds.
  * Every second, it reads the node's numbers. Every 10 seconds, it looks for
    long message queues.

If the load test crashes or the network goes away, the agent stops by itself.

Watching costs a little. Against one Phoenix server holding hundreds of
thousands of connections, the server's CPU was about 6 points higher with the
probe on. If you need the exact maximum, run it once without.

## What you get

The summary gets a `server` section with the node at its busiest, and the
dashboard and the HTML report chart it second by second:

```
  server
    app@10.0.0.5 at its busiest: schedulers 87% busy, 27.85 GB of memory, 1,200,484 processes, run queue 717
```

And there are new metrics, timed by the app itself:

| Metric | What it is |
|---|---|
| `server.http` | HTTP requests, from `Plug.Telemetry` |
| `server.channel.join`, `server.channel.event` | Channel joins and events |
| `server.live.mount`, `server.live.event` | LiveView mounts and events |
| `server.ecto.query`, `server.ecto.queue` | Ecto queries, and how long they waited for a connection |

They work like any other metric, so you can set thresholds on them:

```elixir
thresholds: [{"server.ecto.queue", p95: 50}]
```

## Finding the bottleneck

| What you see | What it usually means |
|---|---|
| Schedulers near 100%, run queue climbing | The node is out of CPU |
| Memory climbing with users, then a crash | The node is out of memory. Work out the memory per connection, and size for it |
| One process with a long message queue | That process can't keep up, and everything waiting on it slows down |
| `server.ecto.queue` growing while `server.ecto.query` stays flat | The pool is too small, or queries hold connections too long |
| The app's own timings are fast, but the load test's are slow | The time is going somewhere else, such as the network, a proxy, or the load test itself |

When a `--find-limit` step fails, its verdict says if the server's schedulers
ran out or if the server went down, and warns you if the load test was the one
too busy to trust.

Past 20,000 processes, the agent only checks the named processes for long
queues, plus a random sample of a thousand others. Asking a process for its
queue wakes it, and waking every connection's process would change what you're
measuring. Most real bottlenecks are named anyway, such as a PubSub or a pool.

If your app can't accept a distribution connection at all, `--probe` won't work
for now. That's on the roadmap.
