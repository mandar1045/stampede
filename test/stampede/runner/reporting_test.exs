defmodule Stampede.Runner.ReportingTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Stampede.Test.{Checking, Custom, Observed}

  test "records a timeline with a point per second" do
    result = Stampede.run(Custom, vus: 2, duration: 2_500)

    assert [first, second, last] = result.timeline
    assert first.at >= 1_000 and second.at >= 2_000 and last.at >= 2_500
    assert first.vus == 2
    assert first.metrics["nap"].count > 0

    in_timeline = result.timeline |> Enum.map(& &1.metrics["nap"].count) |> Enum.sum()
    assert_in_delta in_timeline, result.metrics["nap"].count, 2
  end

  test "evaluates checks" do
    result =
      Stampede.run(Checking,
        vus: 1,
        duration: 300,
        thresholds: [{"even iteration", failed_rate: 0.6}, {"even iteration", failed: 0}]
      )

    assert %{type: :check, passed: passed, failed: failed} = result.metrics["even iteration"]
    assert passed > 0 and failed > 0 and abs(passed - failed) <= 1

    assert [%{stat: :failed_rate, passed?: true}, %{stat: :failed, passed?: false}] =
             result.thresholds
  end

  test "emits telemetry events for the run" do
    test = self()

    :telemetry.attach_many(
      "#{inspect(test)}",
      [[:stampede, :run, :start], [:stampede, :run, :interval], [:stampede, :run, :stop]],
      # Other tests run at the same time, and a handler that raises is detached.
      fn event, measurements, metadata, _config ->
        if metadata.scenario == Observed, do: send(test, {event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("#{inspect(test)}") end)
    result = Stampede.run(Observed, vus: 1, duration: 1_200)

    assert_received {[:stampede, :run, :start], %{system_time: _}, %{options: options}}
    assert options[:vus] == 1
    assert_received {[:stampede, :run, :interval], %{vus: 1}, %{interval: %{at: at}}}
    assert at >= 1_000
    assert_received {[:stampede, :run, :stop], %{duration: _}, %{result: ^result}}
  end

  test "prints progress" do
    output = capture_io(fn -> Stampede.run(Custom, vus: 1, duration: 1_100, progress: true) end)

    assert output =~ ~r/1\.\ds  vus: 1  iterations: \d+  errors: 0/
  end
end
