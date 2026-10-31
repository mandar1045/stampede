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
    assert length(String.split(html, ~s(<figure class="chart"))) == 4
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
end
