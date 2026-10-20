defmodule Stampede.PlanTest do
  use ExUnit.Case, async: true

  alias Stampede.Plan

  defp plan(opts) do
    defaults = [stages: nil, vus: 1, duration: nil, rate: nil, rate_stages: nil, max_vus: 100]
    Plan.from_options(Keyword.merge(defaults, opts))
  end

  describe "VUs" do
    test "ramp in a straight line between targets" do
      plan = plan(stages: [{100, 10}, {100, 10}, {50, 0}])

      assert plan.mode == :vus
      assert Plan.duration(plan) == 250
      assert Plan.target_at(plan, 0) == 0
      assert Plan.target_at(plan, 50) == 5
      assert Plan.target_at(plan, 100) == 10
      assert Plan.target_at(plan, 150) == 10
      assert Plan.target_at(plan, 225) == 5
      assert Plan.target_at(plan, 250) == 0
    end

    test "jump to the target of stages with no duration" do
      assert Plan.target_at(plan(stages: [{0, 8}, {100, 8}]), 0) == 8
    end

    test "accept anything to_timeout/1 does" do
      assert plan(stages: [{[second: 2], 1}, {Duration.new!(minute: 1), 1}]).stages ==
               [{2_000, 1}, {60_000, 1}]
    end

    test "turn :vus and :duration into a constant stage" do
      assert plan(vus: 5, duration: 1_000).stages == [{0, 5}, {1_000, 5}]
    end
  end

  describe "rates" do
    test "start iterations at a constant rate" do
      plan = plan(rate: 20, duration: 2_000)

      assert plan.mode == :rate
      assert Plan.started_by(plan, 0) == 0
      assert Plan.started_by(plan, 500) == 10
      assert Plan.started_by(plan, 2_000) == 40
    end

    test "ramp the rate in a straight line" do
      plan = plan(rate_stages: [{1_000, 10}, {1_000, 10}, {1_000, 0}])

      assert Plan.started_by(plan, 1_000) == 5
      assert Plan.started_by(plan, 2_000) == 15
      assert Plan.started_by(plan, 2_500) == 19
      assert Plan.started_by(plan, 3_000) == 20
      assert Plan.target_at(plan, 500) == 5
    end

    test "accept rates below one per second" do
      assert Plan.started_by(plan(rate: 0.5, duration: 10_000), 10_000) == 5
    end
  end

  test "share/3 splits a total between nodes" do
    assert for(index <- 0..2, do: Plan.share(10, index, 3)) == [4, 3, 3]
    assert for(index <- 0..1, do: Plan.share(1, index, 2)) == [1, 0]
  end

  test "raises on invalid options" do
    assert_raise ArgumentError, ~r/:duration to be given/, fn -> plan([]) end
    assert_raise ArgumentError, ~r/:duration to be given/, fn -> plan(rate: 10) end
    assert_raise ArgumentError, ~r/only one of/, fn -> plan(stages: [{0, 1}], rate: 1) end
    assert_raise ArgumentError, ~r/non-empty list/, fn -> plan(stages: []) end
    assert_raise ArgumentError, ~r/non-negative integer/, fn -> plan(stages: [{100, -1}]) end
    assert_raise ArgumentError, ~r/non-negative integer/, fn -> plan(stages: [{100, 1.5}]) end
    assert_raise ArgumentError, ~r/non-negative number/, fn -> plan(rate_stages: [{100, -1}]) end
    assert_raise ArgumentError, ~r/finite/, fn -> plan(stages: [{:infinity, 1}]) end
    assert_raise ArgumentError, ~r/to_timeout/, fn -> plan(stages: [{-5, 1}]) end
    assert_raise ArgumentError, ~r/:max_vus/, fn -> plan(rate: 1, duration: 10, max_vus: 0) end
  end
end
