defmodule Stampede.MetricsTest do
  use ExUnit.Case, async: true

  alias Stampede.Metrics

  test "timings are within 1% of the exact values" do
    table = Metrics.new()
    for microseconds <- 1..10_000, do: Metrics.record(table, "latency", microseconds)

    %{metrics: %{"latency" => summary}} = Metrics.summary(table, 1_000)

    assert summary.type == :timing
    assert summary.count == 10_000
    assert summary.rate == 10_000.0
    assert_in_delta summary.mean, 5.0005, 0.000001

    for {stat, exact} <- [min: 0.001, p50: 5.0, p90: 9.0, p95: 9.5, p99: 9.9, max: 10.0] do
      assert_in_delta Map.fetch!(summary, stat) / exact, 1.0, 0.01 + 1.0e-9
    end
  end

  test "records durations of zero" do
    table = Metrics.new()
    Metrics.record(table, "instant", 0)

    assert %{metrics: %{"instant" => %{count: 1, min: +0.0, p99: +0.0, max: +0.0}}} =
             Metrics.summary(table, 1_000)
  end

  test "counts" do
    table = Metrics.new()
    Metrics.increment(table, "errors")
    Metrics.increment(table, "errors", 2)
    Metrics.record(table, "latency", 10)

    assert %{metrics: %{"errors" => %{type: :counter, count: 3, rate: 1.5}}} =
             Metrics.summary(table, 2_000)

    assert Metrics.count(table, "errors") == 3
    assert Metrics.count(table, "latency") == 1
    assert Metrics.count(table, "missing") == 0
  end

  test "groups errors by kind and keeps the first message" do
    table = Metrics.new()
    Metrics.error(table, :error, %RuntimeError{message: "first"}, [])
    Metrics.error(table, :error, %RuntimeError{message: "second"}, [])
    Metrics.error(table, :exit, {:timeout, {GenServer, :call, [:server, :ping, 5_000]}}, [])

    assert %{errors: [first, second]} = Metrics.summary(table, 1_000)
    assert first == %{message: "** (RuntimeError) first", count: 2}

    assert %{message: "** (exit) exited in: GenServer.call(:server, :ping, 5000) " <> _, count: 1} =
             second
  end

  test "does nothing without a table" do
    assert Metrics.record(nil, "latency", 10) == :ok
    assert Metrics.increment(nil, "errors") == :ok
    assert Metrics.error(nil, :error, %RuntimeError{}, []) == :ok
  end

  test "does nothing once the table is deleted" do
    table = Metrics.new()
    :ets.delete(table)

    assert Metrics.record(table, "latency", 10) == :ok
    assert Metrics.increment(table, "errors") == :ok
  end
end
