defmodule Stampede.LimitTest do
  use ExUnit.Case, async: true

  # With VUs 1 to n running, the p95 of "latency" is about n * 10ms, so a
  # p95 limit of 25ms holds 2 VUs and fails at 3.
  defmodule Crowded do
    use Stampede.Scenario

    @impl true
    def options, do: [thresholds: [{"latency", p95: 25}]]

    @impl true
    def run(vu) do
      Stampede.record("latency", vu.id * 10)
      Process.sleep(20)
    end
  end

  @fast [step: 1, ramp: 0, hold: 2_000]

  test "finds the most VUs the thresholds allow, and stops at the first step that fails" do
    started_at = System.monotonic_time(:millisecond)
    result = Stampede.run(Crowded, find_limit: @fast)

    assert %{value: 2, by: :vus, up_to?: false, steps: [one, two, three]} = result.limit
    assert {one.target, one.passed?} == {1, true}
    assert {two.target, two.passed?} == {2, true}
    assert {three.target, three.passed?} == {3, false}
    assert result.limit.failed == three
    assert [%{metric: "latency", stat: :p95, passed?: false}] = three.thresholds
    assert three.metrics["latency"].p95 >= 25

    assert result.passed?
    assert result.thresholds == []

    # Three steps of 2 seconds, not the 10,000 the defaults would allow. The
    # next step may start before the one that failed is checked.
    assert System.monotonic_time(:millisecond) - started_at < 9_000
    most_vus = result.timeline |> Enum.map(& &1.vus) |> Enum.max()
    assert most_vus in 3..4

    summary = Stampede.Reporter.format(result)
    assert summary =~ ~r/Held 2 VUs\. At 3 VUs, latency p95 was 3\d\.\d\dms, over 25\.00ms/
    assert summary =~ ~r/\n  1 +10\.00ms +pass\n/
    assert summary =~ ~r/\n  3 +3\d\.\d\dms +FAIL\n/
    refute summary =~ "thresholds"

    html = Stampede.Reporter.to_html(result)
    assert html =~ "<span>Limit</span><strong>2 VUs</strong>"
    assert html =~ "<h3>Limit</h3>"
    assert html =~ ~s(<span class="status failed">over</span>)

    assert %{"limit" => %{"value" => 2, "steps" => [_, _, _]}} =
             result |> Stampede.Reporter.to_json() |> JSON.decode!()

    badge = Stampede.Reporter.to_badge(result)
    assert badge =~ ~s(aria-label="load tested: 2 VUs")
    assert badge =~ "<svg"
  end

  test "to_badge/1 needs the result of a run with :find_limit" do
    assert_raise ArgumentError, ~r/with :find_limit/, fn ->
      Stampede.Reporter.to_badge(%Stampede.Result{scenario: Crowded, duration: 1})
    end

    limit = %{by: :vus, value: nil, up_to?: false, failed: nil, min: nil, steps: [%{target: 50}]}
    result = %Stampede.Result{scenario: Crowded, duration: 1, limit: limit}
    assert Stampede.Reporter.to_badge(result) =~ ~s(aria-label="load tested: under 50 VUs")

    result = put_in(result.limit, %{limit | value: 10_000, up_to?: true})
    assert Stampede.Reporter.to_badge(result) =~ ~s(aria-label="load tested: 10,000+ VUs")
  end

  test "fails when even the first step is too much, or the limit is under :min" do
    result = Stampede.run(Crowded, find_limit: @fast ++ [start: 3])
    assert %{value: nil, steps: [%{target: 3, passed?: false}]} = result.limit
    refute result.passed?

    result = Stampede.run(Crowded, find_limit: @fast ++ [up_to: 1, min: 5])
    assert %{value: 1, up_to?: true} = result.limit
    refute result.passed?
  end

  test "stops after the last step when every step passes" do
    result = Stampede.run(Crowded, find_limit: @fast ++ [up_to: 2])

    assert %{value: 2, up_to?: true, failed: nil, steps: [_, _]} = result.limit
    assert result.passed?
  end

  # Each VU connects once and stays, so its "connect" happens during the ramp.
  defmodule Staying do
    use Stampede.Scenario

    @impl true
    def options, do: [thresholds: [{"connect", p95: 100}]]

    @impl true
    def run(_vu) do
      Stampede.record("connect", 5)
      Process.sleep(:infinity)
    end
  end

  test "counts what VUs did during a step's ramp, not just its hold" do
    result = Stampede.run(Staying, find_limit: [step: 1, up_to: 2, ramp: 1_000, hold: 2_000])

    assert %{value: 2, up_to?: true, steps: [one, two]} = result.limit
    assert one.metrics["connect"].count == 1
    assert two.metrics["connect"].count == 1
  end

  test "raises on invalid options" do
    assert_raise ArgumentError, ~r/:thresholds to be given with :find_limit/, fn ->
      Stampede.run(Crowded, find_limit: @fast, thresholds: [])
    end

    assert_raise ArgumentError, ~r/:hold to be at least 2 seconds/, fn ->
      Stampede.run(Crowded, find_limit: [hold: 500])
    end

    assert_raise ArgumentError, ~r/:step to be a positive integer/, fn ->
      Stampede.run(Crowded, find_limit: [step: 0.5])
    end

    assert_raise ArgumentError, ~r/:up_to to be at least :start/, fn ->
      Stampede.run(Crowded, find_limit: [start: 10, up_to: 5])
    end
  end
end
