defmodule Stampede.ThresholdsTest do
  use ExUnit.Case, async: true

  alias Stampede.Thresholds

  @metrics %{
    "channel.join" => %{
      type: :timing,
      count: 10,
      rate: 5.0,
      min: 1.0,
      mean: 2.0,
      p50: 2.0,
      p90: 3.0,
      p95: 4.0,
      p99: 5.0,
      max: 6.0
    },
    "iteration.errors" => %{type: :counter, count: 2, rate: 1.0}
  }

  defp evaluate(thresholds), do: Thresholds.evaluate(Thresholds.normalize(thresholds), @metrics)

  test "passes statistics at or under their limit" do
    results =
      evaluate([{"channel.join", p95: 4, max: 10}, {"iteration.errors", count: 2, rate: 1}])

    assert Enum.all?(results, & &1.passed?)
  end

  test "fails statistics over their limit" do
    assert [%{metric: "channel.join", stat: :p99, limit: 4.5, value: 5.0, passed?: false}] =
             evaluate([{"channel.join", p99: 4.5}])
  end

  test "counts missing counters as zero and fails missing timings" do
    assert [%{value: 0, passed?: true}, %{value: nil, passed?: false}] =
             evaluate([{"ws.connect.errors", count: 0}, {"ws.connect", p95: 100}])
  end

  test "fails timing statistics on counters" do
    assert [%{value: nil, passed?: false}] = evaluate([{"iteration.errors", p95: 1}])
  end

  test "raises on invalid thresholds" do
    assert_raise ArgumentError, ~r/\{metric, limits\} tuple/, fn ->
      Thresholds.normalize([{"x", []}])
    end

    assert_raise ArgumentError, ~r/invalid limit/, fn -> Thresholds.normalize([{"x", p42: 1}]) end
    assert_raise ArgumentError, ~r/to be a list/, fn -> Thresholds.normalize(%{}) end
  end
end
