defmodule Stampede.Runner.GracefulTest do
  use ExUnit.Case, async: true

  alias Stampede.Test.Lingering

  # Lingering iterations take 300ms, longer than these runs.
  defp counts(result), do: {count(result, "started"), count(result, "finished")}

  defp count(result, name) do
    case result.metrics[name] do
      %{count: count} -> count
      nil -> 0
    end
  end

  test "stops VUs at once by default" do
    result = Stampede.run(Lingering, vus: 2, duration: 100)

    assert counts(result) == {2, 0}
    assert result.duration < 300
  end

  test "lets VUs finish their iteration at the end of the run" do
    result = Stampede.run(Lingering, vus: 2, duration: 100, graceful_stop: 1_000)

    assert counts(result) == {2, 2}
    assert result.metrics["iteration"].count == 2
    assert result.duration in 300..1_000
    assert [%{vus: 2, at: at}, %{at: last}] = result.timeline
    assert at < 300 and last == result.duration
  end

  test "stops VUs that do not finish in time" do
    result = Stampede.run(Lingering, vus: 2, duration: 100, graceful_stop: 50)

    assert counts(result) == {2, 0}
    assert result.duration in 150..300
  end

  test "lets VUs finish their iteration during a ramp down" do
    result =
      Stampede.run(Lingering, stages: [{0, 4}, {50, 4}, {0, 1}, {200, 1}], graceful_stop: 1_000)

    {started, finished} = counts(result)
    assert started == finished and started >= 4
  end

  test "lets iterations started at a rate finish" do
    result = Stampede.run(Lingering, rate: 20, duration: 200, graceful_stop: 1_000)

    assert counts(result) == {4, 4}
  end

  test "raises on invalid graceful stops" do
    assert_raise ArgumentError, ~r/finite/, fn ->
      Stampede.run(Lingering, vus: 1, duration: 100, graceful_stop: :infinity)
    end
  end
end
