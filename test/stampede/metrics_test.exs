defmodule Stampede.MetricsTest do
  use ExUnit.Case, async: true

  alias Stampede.Metrics

  defp record_microseconds(table, name, microseconds) do
    Metrics.record(table, name, System.convert_time_unit(microseconds, :microsecond, :native))
  end

  defp summary(table, duration), do: table |> Metrics.rows() |> Metrics.summary(duration)

  test "timings are within 1% of the exact values" do
    table = Metrics.new()
    for microseconds <- 1..10_000, do: record_microseconds(table, "latency", microseconds)

    %{metrics: %{"latency" => summary}} = summary(table, 1_000)

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
             summary(table, 1_000)
  end

  test "counts" do
    table = Metrics.new()
    Metrics.increment(table, "errors")
    Metrics.increment(table, "errors", 2)
    record_microseconds(table, "latency", 10)

    assert %{metrics: %{"errors" => %{type: :counter, count: 3, rate: 1.5}}} =
             summary(table, 2_000)

    assert Metrics.count(Metrics.rows(table), "errors") == 3
    assert Metrics.count(Metrics.rows(table), "latency") == 1
    assert Metrics.count(Metrics.rows(table), "missing") == 0
  end

  test "checks" do
    table = Metrics.new()
    for passed? <- [true, true, true, false], do: Metrics.check(table, "status is 200", passed?)

    assert %{
             metrics: %{
               "status is 200" => %{
                 type: :check,
                 count: 4,
                 passed: 3,
                 failed: 1,
                 failed_rate: 0.25,
                 rate: 2.0
               }
             }
           } = summary(table, 2_000)
  end

  test "groups errors by kind and keeps the first message" do
    table = Metrics.new()
    Metrics.error(table, :error, %RuntimeError{message: "first"}, [])
    Metrics.error(table, :error, %RuntimeError{message: "second"}, [])
    Metrics.error(table, :exit, {:timeout, {GenServer, :call, [:server, :ping, 5_000]}}, [])

    assert %{errors: [first, second]} = summary(table, 1_000)
    assert first == %{message: "** (RuntimeError) first", count: 2}

    assert %{message: "** (exit) exited in: GenServer.call(:server, :ping, 5000) " <> _, count: 1} =
             second
  end

  test "deltas between snapshots summarize what happened in between" do
    table = Metrics.new()
    record_microseconds(table, "latency", 1_000)
    Metrics.increment(table, "errors")
    before = Metrics.snapshot(table)

    record_microseconds(table, "latency", 3_000)
    record_microseconds(table, "latency", 3_000)
    delta = table |> Metrics.snapshot() |> Metrics.delta(before)

    assert %{metrics: metrics} = Metrics.summary(delta, 1_000)
    assert %{count: 2, p50: p50} = metrics["latency"]
    assert_in_delta p50, 3.0, 0.03
    refute Map.has_key?(metrics, "errors")
  end

  test "merges rows from several tables" do
    [left, right] = [Metrics.new(), Metrics.new()]
    record_microseconds(left, "latency", 1_000)
    record_microseconds(right, "latency", 1_000)
    record_microseconds(right, "latency", 9_000)
    Metrics.error(left, :error, %RuntimeError{message: "left"}, [])
    Metrics.error(right, :error, %RuntimeError{message: "right"}, [])

    merged = Metrics.merge([Metrics.rows(left), Metrics.rows(right)])

    assert %{metrics: %{"latency" => %{count: 3}}, errors: [%{count: 2, message: message}]} =
             Metrics.summary(merged, 1_000)

    assert message in ["** (RuntimeError) left", "** (RuntimeError) right"]
  end

  test "emits telemetry events" do
    test = self()
    events = [[:stampede, :timing], [:stampede, :counter], [:stampede, :check]]

    :telemetry.attach_many(
      "#{inspect(test)}",
      events,
      fn event, measurements, metadata, _config ->
        send(test, {event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("#{inspect(test)}") end)

    table = Metrics.new()
    Metrics.record(table, "telemetry.latency", 42)
    Metrics.increment(table, "telemetry.errors", 3)
    Metrics.check(table, "telemetry.check", false)

    assert_received {[:stampede, :timing], %{duration: 42}, %{name: "telemetry.latency"}}
    assert_received {[:stampede, :counter], %{count: 3}, %{name: "telemetry.errors"}}

    assert_received {[:stampede, :check], %{count: 1}, %{name: "telemetry.check", passed?: false}}
  end

  test "does nothing without a table" do
    assert Metrics.record(nil, "latency", 10) == :ok
    assert Metrics.increment(nil, "errors") == :ok
    assert Metrics.check(nil, "check", true) == :ok
    assert Metrics.error(nil, :error, %RuntimeError{}, []) == :ok
  end

  test "does nothing once the table is deleted" do
    table = Metrics.new()
    :ets.delete(table)

    assert Metrics.record(table, "latency", 10) == :ok
    assert Metrics.increment(table, "errors") == :ok
  end
end
