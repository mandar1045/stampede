defmodule Stampede.ReporterTest do
  use ExUnit.Case, async: true

  alias Stampede.{Reporter, Result}

  test "formats metrics, thresholds and errors" do
    result = %Result{
      scenario: MyApp.Load.Lobby,
      duration: 1_500,
      metrics: %{
        "channel.join" => %{
          type: :timing,
          count: 3,
          rate: 2.0,
          min: 0.5,
          mean: 1.25,
          p50: 1.0,
          p90: 2.0,
          p95: 2.0,
          p99: 2.0,
          max: 1_500.0
        },
        "iteration.errors" => %{type: :counter, count: 1, rate: 0.67}
      },
      thresholds: [
        %{metric: "channel.join", stat: :p95, limit: 250, value: 2.0, passed?: true},
        %{metric: "iteration.errors", stat: :count, limit: 0, value: 1, passed?: false},
        %{metric: "ws.connect", stat: :p95, limit: 100, value: nil, passed?: false}
      ],
      errors: [%{message: "** (RuntimeError) boom", count: 1}],
      passed?: false
    }

    output = Reporter.format(result)

    assert output =~ "MyApp.Load.Lobby ran for 1.5s"
    assert output =~ ~r/channel\.join\s+3\s+2\.00\s+1\.25ms\s+1\.00ms\s+(2\.00ms\s+){3}1\.50s/
    assert output =~ ~r/iteration\.errors\s+1\s+0\.67\n/
    assert output =~ "pass  channel.join p95 <= 250.00ms (2.00ms)"
    assert output =~ "FAIL  iteration.errors count <= 0 (1)"
    assert output =~ "FAIL  ws.connect p95 <= 100.00ms (no samples)"
    assert output =~ "1x ** (RuntimeError) boom"
  end

  test "formats runs without metrics" do
    output = Reporter.format(%Result{scenario: MyApp.Load.Lobby, duration: 0})

    assert output =~ "no metrics were recorded"
  end

  @check %{type: :check, count: 4, rate: 4.0, passed: 3, failed: 1, failed_rate: 0.25}

  test "formats checks apart from the other metrics" do
    result = %Result{
      scenario: MyApp.Load.Lobby,
      duration: 1_000,
      metrics: %{"status is 200" => @check},
      thresholds: [
        %{metric: "status is 200", stat: :failed_rate, limit: 0.1, value: 0.25, passed?: false}
      ]
    }

    output = Reporter.format(result)

    assert output =~ "  checks\n     75.0%  status is 200 (3 of 4)\n"
    assert output =~ "FAIL  status is 200 failed_rate <= 0.10 (0.25)"
    refute output =~ "metric"
    refute output =~ "no metrics were recorded"
  end

  test "to_json/1 encodes every part of the result" do
    result = %Result{
      scenario: MyApp.Load.Lobby,
      duration: 1_000,
      metrics: %{"status is 200" => @check},
      timeline: [%{at: 1_000, vus: 2, metrics: %{"status is 200" => @check}}],
      thresholds: [%{metric: "status is 200", stat: :failed, limit: 0, value: 1, passed?: false}],
      errors: [%{message: "** (RuntimeError) boom", count: 1}],
      passed?: false
    }

    assert JSON.decode!(Reporter.to_json(result)) == %{
             "scenario" => "MyApp.Load.Lobby",
             "duration" => 1_000,
             "passed?" => false,
             "limit" => nil,
             "server" => nil,
             "metrics" => %{
               "status is 200" => %{
                 "type" => "check",
                 "count" => 4,
                 "rate" => 4.0,
                 "passed" => 3,
                 "failed" => 1,
                 "failed_rate" => 0.25
               }
             },
             "timeline" => [
               %{
                 "at" => 1_000,
                 "vus" => 2,
                 "metrics" => %{
                   "status is 200" => %{
                     "type" => "check",
                     "count" => 4,
                     "rate" => 4.0,
                     "passed" => 3,
                     "failed" => 1,
                     "failed_rate" => 0.25
                   }
                 }
               }
             ],
             "thresholds" => [
               %{
                 "metric" => "status is 200",
                 "stat" => "failed",
                 "limit" => 0,
                 "value" => 1,
                 "passed?" => false
               }
             ],
             "errors" => [%{"message" => "** (RuntimeError) boom", "count" => 1}]
           }
  end

  @join %{
    type: :timing,
    count: 2,
    rate: 2.0,
    min: 1.0,
    mean: 1.5,
    p50: 1.0,
    p90: 2.0,
    p95: 2.0,
    p99: 2.0,
    max: 2.0
  }

  test "to_html/1 renders charts and tables in one page" do
    result = %Result{
      scenario: MyApp.Load.Lobby,
      duration: 2_000,
      metrics: %{"channel.join" => @join, ~s(<b> & "quoted") => @check},
      timeline: [
        %{at: 1_000, vus: 2, metrics: %{}},
        %{at: 2_000, vus: 4, metrics: %{"channel.join" => @join}}
      ],
      thresholds: [%{metric: "channel.join", stat: :p95, limit: 1, value: 2.0, passed?: false}],
      errors: [%{message: "** (RuntimeError) <script>", count: 3}],
      passed?: false
    }

    html = Reporter.to_html(result)

    assert html =~ ~r/\A<!doctype html>/
    assert html =~ "<h2>MyApp.Load.Lobby</h2>"
    assert html =~ ~s(<span class="status failed">Failed</span>)
    # The users, and channel.join. Nothing was counted, so no chart of it.
    assert length(String.split(html, ~s(<figure class="chart))) == 3
    assert html =~ ~s(<figure class="chart wide")
    assert html =~ ~s(<circle class="dot s1")
    assert html =~ "&lt;b&gt; &amp; &quot;quoted&quot;"
    assert html =~ "** (RuntimeError) &lt;script&gt;"
    refute html =~ "<b> &"
    assert length(String.split(html, "<script")) == 2
  end

  test "shows what the server looked like at its busiest" do
    server = %{busy: 0.42, memory: 18_100_000_000, processes: 800_123, run_queue: 3}

    result = %Result{
      scenario: Lobby,
      duration: 2_000,
      timeline: [
        %{at: 1_000, vus: 1, busy: 0.1, metrics: %{}, server: server},
        %{at: 2_000, vus: 1, busy: 0.1, metrics: %{}}
      ],
      server:
        Map.merge(server, %{
          nodes: ["app@10.0.0.1"],
          queues: [%{length: 1_204, process: "Phoenix.PubSub"}]
        })
    }

    summary = Reporter.format(result)

    assert summary =~
             "\n  server\n    app@10.0.0.1 at its busiest: schedulers 42% busy, 18.10 GB of " <>
               "memory, 800,123 processes, run queue 3\n"

    assert summary =~ "longest message queues\n      1,204  Phoenix.PubSub\n"

    html = Reporter.to_html(result)
    assert html =~ "<h3>Server</h3>"
    assert html =~ "<span>Server schedulers</span><strong>42% busy</strong>"
    assert html =~ "<span>Server memory</span><strong>18.10 GB</strong>"
    assert html =~ "1,204 &middot; Phoenix.PubSub"
    assert html =~ ~s(<b>Server processes</b>)
  end

  test "says when the server was the one out of CPU at the limit" do
    thresholds = [%{metric: "x", stat: :p95, value: 2_000.0, limit: 1_000, passed?: false}]
    step = %{target: 500, busy: 0.4, server_busy: 0.97, passed?: false, thresholds: thresholds}

    result = %Result{
      scenario: Lobby,
      duration: 1_000,
      limit: %{by: :vus, value: 400, failed: step, up_to?: false, min: nil, steps: [step]}
    }

    assert Reporter.format(result) =~ "The server's schedulers were 97% busy at that step"
  end

  test "says when the database was the limit, and what Postgres was waiting on" do
    thresholds = [%{metric: "chat.send", stat: :p95, value: 640.0, limit: 500, passed?: false}]

    step = %{
      target: 60_000,
      busy: 0.1,
      server_busy: 0.3,
      server_lost?: false,
      passed?: false,
      thresholds: thresholds,
      pool_wait: 300.0,
      pool_size: 10,
      database_waits: %{"LWLock:WALWrite" => 40, "IO:WalSync" => 8, "running" => 12},
      database_seconds: 30
    }

    limit = %{by: :vus, value: 40_000, failed: step, up_to?: false, min: nil, steps: [step]}
    summary = Reporter.format(%Result{scenario: Chat, duration: 1_000, limit: limit})

    assert summary =~
             "Held 40,000 VUs. At 60,000 VUs, chat.send p95 was 640.00ms, over 500.00ms. " <>
               "Queries waited up to 300.00ms for one of the database pool's 10 connections. " <>
               "Postgres was mostly waiting on WALWrite, writing its log to disk before each " <>
               "commit. The app's schedulers were only 30% busy, so the database was the limit, " <>
               "not the app"

    # A pool that kept up, and a Postgres that was mostly idle, aren't worth a mention.
    calm = %{step | pool_wait: 4.0, database_waits: %{"running" => 3}}

    summary =
      Reporter.format(%Result{scenario: Chat, duration: 1_000, limit: %{limit | failed: calm}})

    refute summary =~ "pool"
    refute summary =~ "Postgres"
  end

  @stock_settings %{
    "shared_buffers" => %{value: "128MB", default: true},
    "effective_cache_size" => %{value: "4GB", default: true},
    "work_mem" => %{value: "4MB", default: true},
    "random_page_cost" => %{value: "4", default: true},
    "max_wal_size" => %{value: "1GB", default: true},
    "max_connections" => %{value: "100", default: true},
    "synchronous_commit" => %{value: "on", default: true}
  }

  test "says what to change when the database was the limit on Postgres's defaults" do
    thresholds = [%{metric: "chat.send", stat: :p95, value: 640.0, limit: 500, passed?: false}]

    step = %{
      target: 60_000,
      busy: 0.1,
      server_busy: 0.3,
      server_lost?: false,
      passed?: false,
      thresholds: thresholds,
      pool_wait: 300.0,
      pool_size: 10,
      database_waits: %{"LWLock:WALWrite" => 40, "running" => 12},
      database_seconds: 30,
      database_settings: @stock_settings
    }

    limit = %{by: :vus, value: 40_000, failed: step, up_to?: false, min: nil, steps: [step]}
    summary = Reporter.format(%Result{scenario: Chat, duration: 1_000, limit: limit})

    assert summary =~
             "so the database was the limit, not the app. Postgres allows 100 connections, so " <>
               "the pool can grow past 10. Postgres still has its default shared_buffers " <>
               "(128MB), effective_cache_size (4GB), work_mem (4MB), random_page_cost (4) and " <>
               "max_wal_size (1GB), which suit a small machine, so tuning them may raise this limit"

    assert Reporter.to_html(%Result{scenario: Chat, duration: 1_000, limit: limit}) =~
             "the pool can grow past 10"

    # Tuned, with a pool that kept up: nothing left to suggest about either.
    tuned =
      @stock_settings
      |> Map.put("shared_buffers", %{value: "16GB", default: false})
      |> Map.put("effective_cache_size", %{value: "48GB", default: false})
      |> Map.put("work_mem", %{value: "16MB", default: false})
      |> Map.put("random_page_cost", %{value: "1.1", default: false})
      |> Map.put("max_wal_size", %{value: "16GB", default: false})

    tuned_step = %{step | pool_wait: 4.0, database_settings: tuned}

    summary =
      Reporter.format(%Result{
        scenario: Chat,
        duration: 1_000,
        limit: %{limit | failed: tuned_step}
      })

    assert summary =~ "Postgres was mostly waiting on WALWrite"
    refute summary =~ "pool can grow"
    refute summary =~ "default"

    # When the app's CPU was the limit, Postgres's settings aren't the story.
    busy_app = %{step | server_busy: 0.97, pool_wait: 0.0, database_waits: %{"running" => 3}}

    summary =
      Reporter.format(%Result{
        scenario: Chat,
        duration: 1_000,
        limit: %{limit | failed: busy_app}
      })

    assert summary =~ "The server's schedulers were 97% busy"
    refute summary =~ "small machine"
  end

  test "shows Postgres's settings and how much WAL it wrote" do
    database = %{
      commits: 2454.3,
      writes: 1156.0,
      reads: 34_000.0,
      connections: 11,
      active: 9,
      wal: 12_500_000.0,
      settings: Map.put(@stock_settings, "random_page_cost", %{value: "1.1", default: false})
    }

    server = %{
      nodes: ["app@a"],
      busy: 0.5,
      memory: 1_000_000_000,
      processes: 10,
      run_queue: 0,
      queues: [],
      database: database
    }

    point = fn at, wal ->
      %{at: at, vus: 1, metrics: %{}, server: %{busy: 0.5, database: %{database | wal: wal}}}
    end

    timeline = [point.(1_000, 2_000_000.0), point.(2_000, 12_500_000.0)]
    result = %Result{scenario: Chat, duration: 2_000, server: server, timeline: timeline}

    summary = Reporter.format(result)
    assert summary =~ "11 connections, 12.50 MB of WAL/s\n"

    assert summary =~
             "    postgres settings: shared_buffers 128MB (default), effective_cache_size 4GB " <>
               "(default), work_mem 4MB (default), random_page_cost 1.1, max_wal_size 1GB " <>
               "(default), max_connections 100 (default), synchronous_commit on (default)\n"

    html = Reporter.to_html(result)
    assert html =~ "Postgres settings: shared_buffers 128MB (default)"
    assert html =~ "Postgres WAL written, MB per second"
  end

  test "shows the database at its busiest" do
    server = %{
      nodes: ["app@a"],
      busy: 0.5,
      memory: 1_000_000_000,
      processes: 10,
      run_queue: 0,
      queues: [],
      database: %{commits: 2454.3, writes: 1156.0, reads: 34_000.0, connections: 11, active: 9},
      pool: %{size: 10, wait_ms: 300.0}
    }

    result = %Result{scenario: Chat, duration: 1_000, server: server}

    assert Reporter.format(result) =~
             "    database at its busiest: 2,454 commits/s, 1,156 rows written/s, 34,000 rows " <>
               "read/s, 11 connections\n    database pool of 10: queries waited up to 300.00ms " <>
               "for a connection\n"

    html = Reporter.to_html(result)
    assert html =~ "<span>Database commits</span><strong>2,454/s</strong>"
    assert html =~ "<span>Database pool wait</span><strong>300.00ms</strong>"
  end

  test "says when the server went down, whatever else that step looks like" do
    thresholds = [%{metric: "x", stat: :count, value: 9, limit: 0, passed?: false}]

    step = %{
      target: 600,
      busy: 1.0,
      server_busy: 0.5,
      server_lost?: true,
      passed?: false,
      thresholds: thresholds
    }

    result = %Result{
      scenario: Lobby,
      duration: 1_000,
      limit: %{by: :vus, value: 500, failed: step, up_to?: false, min: nil, steps: [step]},
      server: %{
        nodes: ["app@a"],
        lost: ["app@a"],
        busy: 0.5,
        memory: 1_000_000_000,
        processes: 10,
        run_queue: 0,
        queues: []
      }
    }

    summary = Reporter.format(result)
    assert summary =~ "The server went down during that step"
    refute summary =~ "may be its own"
    assert summary =~ "went down during the run: app@a"
  end

  test "warns when the load test was too busy to trust its timings" do
    point = fn busy -> %{at: 1_000, vus: 1, busy: busy, metrics: %{}} end

    step = %{
      target: 500,
      busy: 0.97,
      passed?: false,
      thresholds: [%{metric: "x", stat: :p95, value: 2_000.0, limit: 1_000, passed?: false}]
    }

    result = %Result{
      scenario: Lobby,
      duration: 3_000,
      timeline: [point.(0.5), point.(0.95), point.(0.99)],
      limit: %{by: :vus, value: 400, failed: step, up_to?: false, min: nil, steps: [step]}
    }

    summary = Reporter.format(result)

    assert summary =~
             "\n  warning\n    The load test was 99% busy at most, and 90% or more for 2s, " <>
               "so timings from then include its own delays."

    assert summary =~
             "At 500 VUs, x p95 was 2.00s, over 1.00s. The load test was 97% busy at that " <>
               "step, so the limit may be its own rather than the server's"

    assert Reporter.to_html(result) =~ "<strong>Warning:</strong> The load test was 99% busy"

    calm = %{result | timeline: [point.(0.5)], limit: nil}
    refute Reporter.format(calm) =~ "warning"
    refute Reporter.to_html(calm) =~ "Warning:"
  end

  test "to_html/1 renders several results, with or without a timeline" do
    results = [
      %Result{scenario: MyApp.Load.Lobby, duration: 0},
      %Result{scenario: MyApp.Load.Checkout, duration: 0}
    ]

    html = Reporter.to_html(results)

    assert html =~ "<h2>MyApp.Load.Lobby</h2>"
    assert html =~ "<h2>MyApp.Load.Checkout</h2>"
    refute html =~ ~s(<figure)
    refute html =~ ~s(<span class="status)
  end

  test "from_json/1 reads back what to_json/1 wrote, limit and server included" do
    step = %{
      target: 100,
      from: 0,
      to: 2_000,
      passed?: true,
      busy: 0.1,
      thresholds: [%{metric: "channel.join", stat: :p95, limit: 500, value: 4.5, passed?: true}],
      database_settings: @stock_settings
    }

    database = %{commits: 1.0, waits: %{"IO:WalSync" => 1}, wal: 10.0, settings: @stock_settings}

    result = %Result{
      scenario: MyApp.Load.Lobby,
      duration: 2_000,
      metrics: %{"channel.join" => @join, "status is 200" => @check},
      timeline: [
        %{
          at: 1_000,
          vus: 2,
          metrics: %{"channel.join" => @join},
          server: %{busy: 0.5, database: database}
        }
      ],
      thresholds: [%{metric: "channel.join", stat: :p95, limit: 500, value: 4.5, passed?: true}],
      errors: [%{message: "boom", count: 1}],
      limit: %{value: 100, by: :vus, up_to?: true, min: nil, failed: nil, steps: [step]},
      server: %{
        busy: 0.5,
        memory: 1,
        processes: 2,
        run_queue: 0,
        nodes: ["app@host"],
        lost: [],
        queues: []
      }
    }

    assert [read] = result |> Reporter.to_json() |> Reporter.from_json()
    assert read == result
    assert Reporter.to_html(read) == Reporter.to_html(result)

    # The files mix stampede.run --out writes hold a list.
    list = "[" <> Reporter.to_json(result) <> "," <> Reporter.to_json(result) <> "]"
    assert [^result, ^result] = Reporter.from_json(list)
  end

  @tag :tmp_dir
  test "mix stampede.report writes the HTML report of saved results", %{tmp_dir: dir} do
    result = %Result{
      scenario: MyApp.Load.Lobby,
      duration: 1_000,
      metrics: %{"channel.join" => @join}
    }

    json = Path.join(dir, "results.json")
    File.write!(json, "[" <> Reporter.to_json(result) <> "]")

    output = ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.Stampede.Report.run([json]) end)
    assert File.read!(Path.join(dir, "report.html")) == Reporter.to_html(result)
    assert output =~ "Wrote "

    ExUnit.CaptureIO.capture_io(fn ->
      Mix.Tasks.Stampede.Report.run([json, "--html", Path.join(dir, "old.html")])
    end)

    assert File.exists?(Path.join(dir, "old.html"))

    File.write!(json, "not json")

    assert_raise Mix.Error, ~r/Could not read/, fn ->
      Mix.Tasks.Stampede.Report.run([json])
    end
  end
end
