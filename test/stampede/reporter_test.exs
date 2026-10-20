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
end
