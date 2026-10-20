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
