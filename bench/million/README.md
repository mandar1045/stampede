# How many connections one Phoenix server holds

This is everything I use to load test a single Phoenix server with hundreds of
thousands of connections on AWS, so you can check my numbers or run it
yourself. The goal is a million. The first real run, on a 4-core server,
held **400,000** with no errors. The [results](#results) are below.

  * [`app/`](app/) is the app under test: a fresh `mix phx.new` app with a
    channel and a LiveView page.
  * [`load/`](load/) holds the two scenarios. `channels.exs` is people in a
    chat room, who join and send a message every 30 to 60 seconds.
    `live.exs` is people on a LiveView page, who click a button every 30 to
    60 seconds.
  * [`aws/`](aws/) starts the machines, runs a scenario and tears it all
    down.
  * [`results/`](results/) has what each run measured.

## The setup

For a million, one server and four load machines, in the same AWS zone:

| | Instance | vCPUs | Memory | On demand, Mumbai |
|---|---|---:|---:|---:|
| Server | r7g.8xlarge | 32 | 256 GB | $1.20/h |
| Load, ×4 | r7g.xlarge | 4 | 32 GB | $0.15/h each |

That's about $1.80 an hour. A Channels run and a LiveView run, with setup,
take under two hours. My AWS account only allowed 8 vCPUs so far, so the
first run used two r7g.xlarge machines instead (see [Results](#results)).

Why these sizes: on my laptop, a held Channels connection took 42 KB on the
Phoenix side and 23 KB on Stampede's. A LiveView user took about 105 KB and
55 KB. So a million LiveView users needs a bit over 100 GB on the server.

## Things that bite at this scale

None of these are Phoenix problems, but each one stops a test long before a
million:

  * **Ports.** One source address only gets about 64,000 ports to the same
    server address and port. Each load machine gets 10 extra private
    addresses (14 on an r7g.xlarge, the most it takes), and every VU
    connects from one of them, through `transport_opts: [ip: ...]`.
  * **File descriptors and processes.** Both sides raise `ulimit -n` and
    start the BEAM with `+P 10000000`. Each connection is two processes on
    each side, and the default limit is about a million processes.
  * **AWS connection tracking.** A security group that only lets in some
    addresses tracks every connection, and each instance size has a cap that
    AWS doesn't publish. Past it, packets are dropped. The security group
    here lets in all TCP, which AWS doesn't track. A firewall on each
    machine, which tracks nothing, closes SSH to everyone but you, and
    Erlang distribution to everything outside the VPC. `run.sh` records the
    `conntrack_allowance_exceeded` counter, so you can see it stayed at 0.
  * **The listen backlog and Bandit's connection limit.** The app takes up
    to 65,536 connections per acceptor and has a backlog of 65,535. That's
    the only change to a stock Phoenix app.
  * **Idle schedulers that spin.** By default the BEAM keeps a scheduler
    spinning for a moment before it sleeps, which shows up as CPU use that
    isn't work. Both sides run with `+sbwt none` so the CPU numbers are the
    work done.
  * **The load test itself.** A load machine that's too busy delays its own
    heartbeats and timings, and from the outside that looks like the server
    failing. Stampede reports how busy it was every second and says so when
    it passes 90%.

## Running it

You need the AWS CLI with credentials that can manage EC2 and EventBridge
Scheduler, and an on-demand vCPU quota of at least 48 in the region.

```console
$ cd aws
$ ./up.sh                               # about 5 minutes
$ ./deploy.sh                           # copies and compiles the code
$ ./run.sh channels 1000000 900 300     # VUs, ramp and hold, in seconds
$ ./run.sh live 1000000 900 300
$ ./down.sh                             # terminates everything
```

`config.sh` has the settings, and each can be changed from the environment,
such as `LOADERS=2 ./up.sh`.

Every machine destroys itself after 4 hours, even if your laptop goes to
sleep halfway through: it schedules its own shutdown at boot, and an
EventBridge schedule terminates them all 5 minutes later in case one can't.
`./status.sh` lists what's running.

## Results

The AI model server runs are in the
[guide](https://github.com/mandar1045/stampede/blob/main/guides/llm.md#a-real-run),
with their results here too, in `20261031-ollama-1-slot` and
`20261031-ollama-4-slots`.

### 400,000 Channels users on a 4-core server (October 29, 2026)

Two r7g.xlarge machines in Mumbai (4 Graviton vCPUs and 32 GB each): one for
Phoenix 1.8.16 with Bandit, one for Stampede. Erlang/OTP 29.1.2 and Elixir
1.20.2 on both.

Every user behaves like Phoenix's JavaScript client: it connects, joins
`room:lobby`, sends a heartbeat every 30 seconds and a message every 30 to
60 seconds, and stays. I let `--find-limit` add 100,000 users at a time, at
1,000 new users a second, and hold each step for a minute:

```console
$ STEP_RAMP=100 ./run.sh channels 0 0 0 --find-limit --start 100000 --step 100000 --up-to 800000 --hold 60s
```

A step passes when joins and messages stay under 1 second at p95, with no
errors at all.

| Users | Join p95 | Message p95 | Errors | Server CPU | Server memory | Load machine CPU |
|---:|---:|---:|---:|---:|---:|---:|
| 100,000 | 5.71ms | 0.57ms | 0 | 1% | 4.9 GB | 45% |
| 200,000 | 6.84ms | 1.35ms | 0 | 3% | 9.5 GB | 60% |
| 300,000 | 9.42ms | 2.67ms | 0 | 9% | 13.9 GB | 67% |
| **400,000** | **12.46ms** | **4.07ms** | **0** | **24%** | **18.1 GB** | **74%** |
| 500,000 | 23.45s | 28.65s | 53,696 | | | 100% |

CPU and memory are averages while each step held. While users were joining,
the server peaked at 47%.

At 500,000 the load machine, not Phoenix, ran out of CPU. Its heartbeats ran
tens of seconds late, so connections were closed for going quiet. Stampede
said as much:

> Held 400,000 VUs. At 500,000 VUs, channel.join p95 was 23.45s, over 1.00s
> and channel.push p95 was 28.65s, over 1.00s and iteration.errors count was
> 53696, over 0. The load test was 100% busy at that step, so the limit may be
> its own rather than the server's

Phoenix logged nothing, not a warning, during the whole run, and AWS dropped
no packets. So 400,000 is what this server held, not where it stops. Finding
that needs more load machines than my account allows yet.

Everything the run measured is in
[`results/20261029-1052-channels-find-limit`](results/20261029-1052-channels-find-limit):
the summary, the HTML report, the JSON, and both machines' CPU and memory
every 10 seconds.

Two earlier runs held the same 400,000. They also found three bugs in
Stampede that this run didn't have: `--find-limit` ignored joins during a
step's ramp, connections failed with `:nxdomain` when the load machine was
busy, and an overloaded run could stall instead of ending. Their results are
here too, in [`20261029-0941-channels-0`](results/20261029-0941-channels-0)
and [`20261029-1006-channels-find-limit`](results/20261029-1006-channels-find-limit).

The three runs cost about $1.30 of AWS credit.
