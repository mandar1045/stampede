defmodule Stampede.StagesTest do
  use ExUnit.Case, async: true

  alias Stampede.Stages

  defp stages(opts) do
    Stages.from_options(Keyword.merge([stages: nil, vus: 1, duration: nil], opts))
  end

  test "ramps in a straight line between targets" do
    stages = stages(stages: [{100, 10}, {100, 10}, {50, 0}])

    assert Stages.duration(stages) == 250
    assert Stages.target_at(stages, 0) == 0
    assert Stages.target_at(stages, 50) == 5
    assert Stages.target_at(stages, 100) == 10
    assert Stages.target_at(stages, 150) == 10
    assert Stages.target_at(stages, 225) == 5
    assert Stages.target_at(stages, 250) == 0
  end

  test "jumps to the target of stages with no duration" do
    stages = stages(stages: [{0, 8}, {100, 8}])

    assert Stages.target_at(stages, 0) == 8
  end

  test "accepts anything to_timeout/1 does" do
    assert stages(stages: [{[second: 2], 1}, {Duration.new!(minute: 1), 1}]) ==
             [{2_000, 1}, {60_000, 1}]
  end

  test "turns :vus and :duration into a constant stage" do
    assert stages(vus: 5, duration: 1_000) == [{0, 5}, {1_000, 5}]
  end

  test "raises on invalid stages" do
    assert_raise ArgumentError, ~r/either :stages or :duration/, fn -> stages([]) end
    assert_raise ArgumentError, ~r/non-empty list/, fn -> stages(stages: []) end

    assert_raise ArgumentError, ~r/non-negative integer target/, fn ->
      stages(stages: [{100, -1}])
    end

    assert_raise ArgumentError, ~r/finite/, fn -> stages(stages: [{:infinity, 1}]) end
    assert_raise ArgumentError, ~r/to_timeout/, fn -> stages(stages: [{-5, 1}]) end
  end
end
