# How many connections one Phoenix server holds

This is everything I use to load test a single Phoenix server with hundreds of
thousands of connections on AWS, so you can check my numbers or run it
yourself. The goal was a million. One 16-core server has now held
**2,000,000** with no errors, and a 4-core one held 600,000. The
[results](#results) are below.

  * [`app/`](app/) is the app under test: a fresh `mix phx.new` app with a
    channel and a LiveView page.
  * [`load/`](load/) holds the two scenarios. `channels.exs` is people in a
    chat room, who join and send a message every 30 to 60 seconds.
    `live.exs` is people on a LiveView page, who click a button every 30 to
    60 seconds.
    `realtime.exs` is people in group chats on Supabase Realtime.
    `chat_db.exs` is people in a chat app that keeps every message in
    Postgres.
  * [`chat/`](chat/) is that chat app: a fresh `mix phx.new` app with Ecto
    and Postgres.
  * [`realtime/`](realtime/) starts the official Supabase Realtime release.
  * [`proof/`](proof/) records real pages during a run, including a real
    `realtime-js` client in Firefox.
  * [`aws/`](aws/) starts the machines, runs a scenario and tears it all
    down.
  * [`results/`](results/) has what each run measured.

## The setup

For two million, one server and eight load machines, in the same AWS zone:

| | Instance | vCPUs | Memory | On demand, Mumbai |
|---|---|---:|---:|---:|
| Server | r7g.4xlarge | 16 | 128 GB | about $0.60/h |
| Load, ×8 | r7g.xlarge | 4 | 32 GB | about $0.15/h each |

That's about $1.80 an hour, and the 2,000,000 run took about an hour with
setup. It uses 48 vCPUs, which is what my AWS account allows. The earlier runs
below used smaller machines.

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

### A chat app on Postgres with 100 million messages (November 8, 2026)

The runs below hold connections that barely touch a database, and the question
I got most after the 2,000,000 one was what happens with a real one. So this is
a chat app that stores every message: [`chat/`](chat/), a fresh `mix phx.new`
app with Ecto's default pool of 10 connections. Postgres 17 runs on its own
r7g.2xlarge (8 cores, 64 GB) with the official image's default settings,
seeded with 1 million users, 10,000 rooms and 100 million messages, 18 GB in
all. The app runs on the same r7g.4xlarge (16 cores) as the 2,000,000 run, and
six r7g.xlarge make the load.

Each user joins a room of about 100 people. Joining reads the room's latest 50
messages from Postgres and marks them read. Then every 30 to 60 seconds they
either send a message, which is written to Postgres before the reply comes
back, or, one time in five, scroll up for the 50 messages before the oldest
they have.

```console
$ DB_TYPE=r7g.2xlarge ZONE=ap-south-1a SERVER_TYPE=r7g.4xlarge LOADERS=6 SOURCE_IPS=14 ./up.sh
$ APP=chat ./deploy.sh
$ PROOF=1 STEP_RAMP=120 ./run-chat.sh --find-limit --start 20000 --step 20000 --up-to 400000 --hold 60s
```

[`20261108-0621-chat_db-0`](results/20261108-0621-chat_db-0):

| Users | Join p95 | Send p95 | Scroll up p95 | Errors | |
|---:|---:|---:|---:|---:|---|
| 20,000 | 4.58ms | 3.20ms | 38.96ms | 0 | pass |
| **40,000** | **6.31ms** | **178.14ms** | **167.77ms** | **0** | **pass** |
| 60,000 | 708.14ms | 640.75ms | 535.20ms | 110,576 | fail |

40,000 held with no errors. At 60,000 channels started crashing, and it wasn't
one wall but three at once. The app's schedulers peaked at 96% busy. Queries
spent nearly all their time waiting for one of the pool's 10 connections:
299.65ms at p95 out of 305.70ms in total, over the whole run. And Postgres's
active sessions were mostly waiting on `WALWrite` and `WalSync`, writing its log
to disk before each commit, more often than they were running queries. That's
in [`db-stats.log`](results/20261108-0621-chat_db-0/db-stats.log), sampled every
10 seconds.

The run wrote 304,355 messages, which is the count in Postgres before and after
([`db-before.txt`](results/20261108-0621-chat_db-0/db-before.txt),
[`db-after.txt`](results/20261108-0621-chat_db-0/db-after.txt)), within 7 of
the 304,348 sends Stampede counted as answered.

That's a much smaller number than 2,000,000, and it should be: every user here
reads and writes a real database. It's also what made me teach `--probe` to
watch the database, so the verdict now says which of those walls it was.

[`20261108-chat-db-cold-cache`](results/20261108-chat-db-cold-cache) is the
first try, straight after seeding, with Postgres's cache still cold. Within
seconds the app's pool was dropping requests from its queue, so I stopped it
and ran again. The `column "chat" does not exist` errors in its `postgres.log`
come from a quoting bug in my stats loop, fixed since.

### 2,000,000 Channels users on a 16-core server (November 4, 2026)

One r7g.4xlarge (16 Graviton cores, 128 GB) running the stock app, and eight
r7g.xlarge for the load, each connecting from 14 extra private addresses. Every
user joins `room:lobby`, sends a heartbeat every 30 seconds and a message every
30 to 60, like Phoenix's JavaScript client, and stays.

```console
$ ZONE=ap-south-1a SERVER_TYPE=r7g.4xlarge LOADER_TYPE=r7g.xlarge LOADERS=8 SOURCE_IPS=14 ./up.sh
$ ./deploy.sh
$ PROOF=1 STEP_RAMP=250 ./run.sh channels 0 0 0 --find-limit --start 1000000 --step 250000 --up-to 3000000 --hold 60s
```

[`20261104-1051-channels-0`](results/20261104-1051-channels-0):

| Users | Server CPU | Server memory | |
|---:|---:|---:|---|
| 1,000,000 | 37–48% | 52 GB | held |
| 1,250,000 | 47–52% | 64 GB | held |
| 1,500,000 | 54–60% | 77 GB | held |
| 1,750,000 | 67–71% | 90 GB | held |
| **2,000,000** | **78–84%** | **103 GB** | **held** |
| 2,250,000 | out of CPU | | failed |

Every step up to 2,000,000 passed with joins and messages under 1 second at p95
and no errors. The first error came at 2,067,672 users, while ramping to
2,250,000, as the server's CPU reached 96%. That step failed, and I stopped the
run while it was failing, so its log ends without Stampede's final summary.
The steps and their verdicts are in [`run.log`](results/20261104-1051-channels-0/run.log).

Memory came to about 51 KB a user, everything on the machine included, so CPU
was the limit, not memory. The kernel's own count of established connections,
every 10 seconds, is in
[`sockets.log`](results/20261104-1051-channels-0/sockets.log). AWS's connection
tracking allowance was never exceeded, and the load machines were 39% busy at
2,000,000.

`PROOF=1` is new: it adds the live dashboard to the run, records it as a video,
logs the server's socket counts and records the terminal.

### 50,000 Supabase Realtime users on a 4-core server (October 31, 2026)

Stock Phoenix tells you what Phoenix can do. This one is a real product: the
official `supabase/realtime:v2.150.2` release, self-hosted on one r7g.xlarge (4
cores, 32 GB), with Postgres on the same machine and three r7g.xlarge for the
load. Each channel has 100 users, and each user sends a broadcast every 30 to 60
seconds that everyone in the channel receives. The write-up is in the
[case study](../../guides/supabase_realtime.md).

```console
$ ZONE=ap-south-1a SERVER_TYPE=r7g.xlarge LOADERS=3 SOURCE_IPS=14 ./up.sh
$ ./deploy.sh
$ PAUSE=30-60 STEP_RAMP=60 ./run-realtime.sh --find-limit --start 10000 --step 10000 --up-to 120000 --hold 60s
$ VUS=50000 RAMP=300 HOLD=600 PAUSE=30-60 PROOF_SECONDS=960 ./run-realtime.sh
```

[`20261031-realtime-find-limit`](results/20261031-realtime-find-limit):

| Users | Join p95 | Round trip p95 | Errors | Server CPU | Server memory | |
|---:|---:|---:|---:|---:|---:|---|
| 10,000 | 5.27ms | 1.72ms | 0 | 17% | 1.8 GB | pass |
| 20,000 | 5.94ms | 2.02ms | 0 | 33% | 2.6 GB | pass |
| 30,000 | 6.31ms | 2.52ms | 0 | 50% | 3.3 GB | pass |
| 40,000 | 8.69ms | 3.53ms | 0 | 67% | 4.0 GB | pass |
| **50,000** | **17.16ms** | **6.44ms** | **0** | **82%** | **4.7 GB** | **pass** |
| 60,000 | 1.06s | 75.38ms | 0 | 94% | 5.4 GB | fail |

The 60,000 step failed on joins, at 1.06s against a limit of 1 second, with the
CPU at 99.9% at its peak. Stampede counted no errors there, but Realtime's log has
one during the step, a metrics poll timing out, and 20 more just after the run,
from joins that timed out. There are none before 60,000. That's in
[`realtime.log`](results/20261031-realtime-find-limit/realtime.log).

[`20261031-realtime-hold-50k`](results/20261031-realtime-hold-50k) then ramped up
over 5 minutes and held 50,000 for 10: 80.9 million messages delivered, about
111,000 a second, with a round trip of 5.71ms at p95 and 10.62ms at p99, and no
errors. The server held at 79% CPU and 4.7 GB, and the load machines peaked at 51%.
Realtime's log has no errors at all, and no warnings until 50,000 users
disconnected at once when the run ended.

[`realtime-metrics.json`](results/20261031-realtime-hold-50k/realtime-metrics.json)
is Realtime's own count, which peaked at 50,001, the users and one real browser,
and [`sockets.log`](results/20261031-realtime-hold-50k/sockets.log) is the kernel's,
every 10 seconds. I also recorded the dashboards, a real `realtime-js` client in
Firefox and the terminal during both runs.

The AI model server runs are in the
[guide](https://github.com/mandar1045/stampede/blob/main/guides/llm.md#a-real-run),
with their results here too, in `20261031-ollama-1-slot` and
`20261031-ollama-4-slots`.

### 600,000 Channels users on a 4-core server (October 31, 2026)

Four r7g.xlarge machines in Mumbai (4 Graviton vCPUs and 32 GB each): one for
Phoenix 1.8.16 with Bandit, and three for Stampede. Everything else is the
same as in the 400,000 run below: the same app, the same users that behave
like Phoenix's JavaScript client, and the same rules for passing a step.

```console
$ ZONE=ap-south-1a SERVER_TYPE=r7g.xlarge LOADERS=3 SOURCE_IPS=14 ./up.sh
$ ./deploy.sh
$ NO_PROBE=1 STEP_RAMP=100 ./run.sh channels 0 0 0 --find-limit --start 100000 --step 100000 --up-to 600000 --hold 60s
```

| Users | Join p95 | Message p95 | Errors | Server CPU | Server memory |
|---:|---:|---:|---:|---:|---:|
| 100,000 | 9.05ms | 0.98ms | 0 | 13% | 5 GB |
| 200,000 | 6.31ms | 1.50ms | 0 | 32% | 10 GB |
| 300,000 | 6.84ms | 1.75ms | 0 | 41% | 14 GB |
| 400,000 | 4.32ms | 1.75ms | 0 | 58% | 19 GB |
| 500,000 | 13.23ms | 3.61ms | 0 | 70% | 23 GB |
| **600,000** | **30.65ms** | **9.80ms** | **0** | **76%** | **28 GB** |

CPU and memory are while each step held. The load machines were never the
limit this time, at 31% busy at most. Memory was: at 600,000 the machine had
98% of its memory in use, so this is about the ceiling for 32 GB. Each
connection took about 47 KB.

I ran it three times, and I want to be straight about all three:

| Run | Probe | Result | Server CPU at 400k |
|---|---|---|---:|
| [`20261031-no-probe`](results/20261031-no-probe) | off | held 600,000 | 58% |
| [`20261031-probe-limited-scan`](results/20261031-probe-limited-scan) | on | held 600,000 | 64% |
| [`20261031-probe-full-scan`](results/20261031-probe-full-scan) | on, an earlier version | held 500,000, then the kernel killed the app for using too much memory at about 598,000 | 48% |

The crash came with an earlier version of the probe, which asked every process
for its message queue every 10 seconds. I replaced that with asking only the
named processes and a small sample. The two runs since both held 600,000, but
at 98% memory there isn't much room, so another crash wouldn't surprise me.

Comparing the two 600,000 runs, the probe costs about 6 points of CPU. I can't
yet explain why the server's CPU is higher than in the 400,000 run below, which
was 24% with one load machine and no probe, or why the crashed run shows the
lowest CPU here. The probe isn't the reason for the first one, since the
no-probe run shows it too.

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
