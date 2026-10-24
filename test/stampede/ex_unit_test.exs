defmodule Stampede.ExUnitTest do
  use ExUnit.Case, async: true

  import Stampede.ExUnit

  alias Stampede.Test.{Checking, Observed}

  test "assert_load/2 returns the result of a run that passed" do
    result =
      assert_load(Observed, vus: 1, duration: 200, thresholds: [{"iteration.errors", count: 0}])

    assert %Stampede.Result{scenario: Observed, passed?: true} = result
    assert result.metrics["iteration"].count > 0
  end

  test "assert_load/2 fails with the summary of a run that did not pass" do
    thresholds = [{"iteration", count: 0}, {"iteration.errors", count: 0}]

    error =
      assert_raise ExUnit.AssertionError, fn ->
        assert_load(Observed, vus: 1, duration: 200, thresholds: thresholds)
      end

    assert error.message =~ "Stampede.Test.Observed failed 1 of 2 thresholds"
    assert error.message =~ "Stampede.Test.Observed ran for"
    assert error.message =~ ~r/FAIL  iteration count <= 0 \(\d+\)/
  end

  test "assert_passed/1 checks results of parallel runs" do
    [observed, checking] =
      Stampede.run_parallel([Observed, Checking],
        vus: 1,
        duration: 200,
        thresholds: [{"even iteration", failed: 0}]
      )

    assert assert_passed(observed) == observed

    error = assert_raise ExUnit.AssertionError, fn -> assert_passed(checking) end
    assert error.message =~ "Stampede.Test.Checking failed 1 of 1 threshold\n"
  end
end
